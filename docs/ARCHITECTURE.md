# Architecture

## Goal

When a voice note recorded on a Pebble Index 01 ring is transcribed and saved into a specific folder of
an Obsidian vault, automatically produce a companion "research note" — web-researched, with a relevant
title and tags — saved back into the same vault, using n8n as the orchestrator and MCP servers as the
agent's tools.

## Why not just watch the vault folder directly?

The vault's primary copy lives on the phone (paired with the ring via the Pebble app). It reaches other
devices/servers through the **Self-hosted LiveSync** Obsidian plugin, configured to replicate through a
self-hosted **MinIO** (S3-compatible) bucket rather than Obsidian's official paid Sync service or a
CouchDB server.

Self-hosted LiveSync does not store your vault in the bucket as plain, individually readable `.md`
files — it replicates its internal document model as encrypted objects. **Confirmed on the real
bucket:** it uses LiveSync's E2EE **"Journal Sync"** mode, storing gzip-then-encrypted journal chunks
named `master-vault<timestamp>-docs.jsonl.gz` plus a `master-vault_00000000-milestone.json`
coordination doc — not plain per-note files, and not a raw CouchDB replication log either. That means
you can't just point a file-watcher (or even `gunzip`) at the MinIO bucket and expect readable
Markdown; you need `livesync-cli` to decrypt and materialize it.

## Getting a real, plain-Markdown mirror on the server

`vrtmrz/obsidian-livesync` ships a companion CLI (`src/apps/cli`, package name `livesync-cli`) that
implements the same sync protocol as the Obsidian plugin, without needing Obsidian (or any Electron/GUI)
running.

**✅ Validated (`spike-livesync-s3`, 2026-08-25) against the real MinIO remote.** Key findings:

- The user's actual remote is **not** CouchDB-over-S3 and not raw per-note files — it's LiveSync's
  **"Journal Sync"** mode (an E2EE, object-storage-native sync protocol, distinct from CouchDB
  replication). The bucket (`obsidian-bucket`) contains encrypted journal chunks named
  `master-vault<timestamp>-docs.jsonl.gz` plus `master-vault_00000000-milestone.json` (a coordination
  doc) and `master-vault_obsidian_livesync_journal_sync_parameters.json`. These are genuinely encrypted
  — even the `.gz` files don't gunzip without going through the CLI's own decryption, confirming true
  end-to-end encryption at rest.
- `livesync-cli`'s shared `@vrtmrz/livesync-commonlib` explicitly implements `LiveSyncJournalReplicator`
  (alongside `LiveSyncCouchDBReplicator`), so Journal Sync is a first-class, supported remote type
  (`"remoteType": "MINIO"` in `settings.json`), not an incidental side effect of S3-compatible CouchDB.
- **Recommended bootstrap path**: rather than hand-typing the MinIO endpoint/bucket/access
  key/secret/passphrase, export the plugin's **Setup URI** from Obsidian (Settings → Sync Settings →
  copy/QR "Setup URI") and apply it directly:
  ```bash
  livesync-cli init-settings /data/livesync-settings.json
  printf '%s\n' "$SETUP_URI_PASSCODE" | \
    livesync-cli /data --settings /data/livesync-settings.json --vault /vault setup "$SETUP_URI"
  ```
  This populates `settings.json` with the real `endpoint`, `bucket`, `accessKey`/`secretKey`,
  `bucketPrefix`, `chunkSplitterVersion`, and E2EE settings verbatim from the plugin's own config —
  no manual transcription, no risk of a typo'd passphrase.
- **First-time device handshake:** a brand-new device (like a freshly bootstrapped CLI) hits a
  **remote lock**: `[Error] The remote database is locked and this device is not yet accepted.` This is
  Journal Sync's safety mechanism — a milestone document on the remote tracks `locked` +
  `accepted_nodes`, and any device not yet in `accepted_nodes` is refused until it either resets its
  local state and re-syncs, or (simpler, and what worked here) the operator runs
  `livesync-cli ... unlock-remote <remote-id>` once. This is a one-time step per new device, not a
  per-sync-cycle requirement.
- `sync` (one-shot) pulls the encrypted replication log but — in CLI mode — does **not** automatically
  materialize it into `.md` files (`[Info] Replication result received, but not processed automatically
  in CLI mode.`). Use `mirror [vault-path]` after a `sync` to write the actual plain-Markdown files to
  disk, or use `daemon` mode, which runs a mirror scan (both directions) on startup and then keeps
  watching. Confirmed: `daemon` mode picks up local filesystem changes via its file watcher and pushes
  a new `docs.jsonl.gz` journal entry within seconds; `rm <path>` + `sync` correctly propagates
  deletions back to the remote too.
- Files written by the official Docker image are owned by **root** inside the container (no non-root
  user is configured), since the image doesn't drop privileges. Anything else that needs to read/write
  the same mounted vault-mirror volume (e.g. `obsidian-mcp`, n8n's Local File Trigger) will need either
  matching container UID/GID, host directory permissions opened up, or the `livesync-cli` container
  configured to run as a specific non-root UID — to be resolved in `vault-mirror-service`.
- The real ring-notes folder in this vault is **`Index Inbox/`** (not a hypothetical `Pebble Notes/`),
  with frontmatter `tags: [index, index_note]` on each transcribed note — useful for wiring the n8n
  Local File Trigger path precisely in `n8n-workflow-trigger`.
- It ships with an official `Dockerfile` (`src/apps/cli/Dockerfile`, built successfully via
  `docker build -f src/apps/cli/Dockerfile -t livesync-cli .` from the repo root) and a systemd unit +
  `install.sh` for non-Docker installs.

The server now ends up with a directory (e.g. `/srv/vault-mirror/`) that always mirrors the real vault
as plain files — this is what n8n and the Obsidian MCP server both operate on.

## Trigger

n8n's **Local File Trigger** node watches the ring-transcript subfolder inside the mounted mirror volume
(e.g. `/srv/vault-mirror/Pebble Notes/`) for new files.

## Agent & tools

The n8n workflow's **AI Agent** node (backed by [OpenRouter](https://openrouter.ai/) — one API key, any
underlying model, chosen per explicit user preference over a locked-in single provider) is given two MCP
tool servers via n8n's **MCP Client Tool** node:

1. **`obsidian-mcp`** (`StevenStavrakis/obsidian-mcp`) — operates directly on the mirrored vault
   directory (no Obsidian process, no REST API plugin required). Exposes tools like
   `obsidian_read_note`, `obsidian_create_note`, `obsidian_search_vault`, `obsidian_add_tags`, etc.
2. **`mcp-searxng`** (`SecretiveShell/MCP-searxng`) — exposes a `search` tool backed by a self-hosted
   **SearXNG** meta search instance, so no third-party search API key is needed.

Both are **stdio** MCP servers by design. n8n's built-in MCP Client Tool node expects an HTTP/SSE
endpoint, so each is wrapped with **`mcp-proxy`** (`sparfenyuk/mcp-proxy`, the Python package — see
**⚠️ below**, this is easy to get wrong), which turns any stdio MCP server into an SSE endpoint with one
command:

```
mcp-proxy --port <port> --host 0.0.0.0 --pass-environment -- <stdio command>
```

This keeps every tool as an independent, network-reachable container — nothing needs to be installed
inside the n8n container itself.

**✅ Validated (`spike-mcp-bridge`, 2026-08-25)** against real containers on `home_server`, including
live round-trip tool calls (not just a handshake check). Key findings:

- **⚠️ `npx -y mcp-proxy` is a trap — it is NOT `sparfenyuk/mcp-proxy`.** There is an unrelated npm
  package also called `mcp-proxy` (`punkpeye/mcp-proxy`, "A TypeScript SSE proxy for MCP servers that
  use stdio transport") that `npx` happily resolves instead, with a completely different CLI (`--server`,
  `--sseEndpoint`, `--streamEndpoint`, camelCase flags, no `--port`/`--host`/`--pass-environment`). The
  original `docker-compose.yml` skeleton used `npx -y mcp-proxy`, which would have silently bridged with
  the *wrong tool*. The real `sparfenyuk/mcp-proxy` is a **Python** package — install it with
  `pip`/`pipx`/`uv`, or run the official `ghcr.io/sparfenyuk/mcp-proxy` image; never `npx`.
- **`mcp-proxy` (PyPI `0.12.0`) needs `mcp` pinned below `2.0`.** Its own `pyproject.toml` declares
  `mcp>=1.27.1` (satisfied by 2.x too), but installing the latest `mcp` (2.1.0) breaks it at import time
  (`ImportError: cannot import name 'request_ctx' from mcp.server.lowlevel.server` — a real upstream
  API change in `mcp` 2.x that `mcp-proxy` 0.12.0 hasn't caught up to). Fix: `pip install 'mcp<2'
  mcp-proxy` (resolves to `mcp==1.29.1`, which works).
- **`mcp-proxy` does not forward environment variables to the spawned stdio child by default.** Without
  `--pass-environment` (or explicit `-e KEY VALUE` per variable), `mcp-searxng`'s `SEARXNG_URL` env var
  was invisible to the child process and every search call failed with a connection error. Always pass
  `--pass-environment` (or explicit `-e`) when the wrapped server reads its config from the environment.
- **`mcp-searxng`'s published PyPI package (`0.1.0`) is stale and incompatible with current SearXNG.**
  Its `Response` Pydantic model requires a `number_of_results` field that this deployment's SearXNG no
  longer returns from `/search?format=json` (confirmed via direct `curl`: the real JSON response has
  `query`, `results`, `infoboxes`, `answers`, `corrections`, `suggestions`, `unresponsive_engines` — no
  `number_of_results`). GitHub's `main` branch has already dropped that field from the model; the fix is
  to install straight from source: `pip install git+https://github.com/SecretiveShell/MCP-searxng.git`
  instead of `pip install mcp-searxng`.
- **`obsidian-mcp@2` requires a pre-existing `.obsidian/` directory inside the vault path**, or it
  refuses to treat the path as a valid vault. LiveSync's Journal Sync (per `spike-livesync-s3`) does
  **not** replicate the `.obsidian/` config folder — only vault content — so the mirrored vault produced
  by `livesync-cli` won't have one. `vault-mirror-service` needs to `mkdir -p` an (empty is fine)
  `.obsidian/` directory once in the mirror path before `mcp-obsidian` starts.
- **Confirmed working invocations** (both run as a single container combining the stdio server's own
  runtime with a `pip`-installed `mcp-proxy`, since no off-the-shelf image bundles both):
  - `obsidian-mcp`: `node:22-slim` base + `python3`/`pip` + `pip install 'mcp<2' mcp-proxy`, then
    `mcp-proxy --port 8801 --host 0.0.0.0 --pass-environment -- npx -y obsidian-mcp@2 serve --vault
    notes=/vault`.
  - `mcp-searxng`: `python:3.12-slim` base + `git` + `pip install 'mcp<2' mcp-proxy
    git+https://github.com/SecretiveShell/MCP-searxng.git`, then `mcp-proxy --port 8802 --host 0.0.0.0
    --pass-environment -- mcp-searxng` (env `SEARXNG_URL=http://searxng:8080`).
- Both expose SSE at `http://<container-name>:<port>/sse` (the default/unnamed-server path). Verified
  reachable via Docker DNS from the *actual, already-running* `n8n` container on the shared
  `n8n_n8n_internal` network — not just a throwaway test client — which is exactly the path n8n's MCP
  Client Tool node will use.
- **Round-tripped real MCP tool calls through each bridge**, not just the SSE handshake: `obsidian-mcp`
  — `obsidian_list_vaults`, `obsidian_read_note` (real `Welcome.md` content), and a throwaway
  `obsidian_create_note` + `obsidian_delete_note` (`mode: "permanent"`) cycle, verified removed from disk
  afterwards; `mcp-searxng` — `search` returned real, live web results (e.g. real repebble.com /
  pebblecart.com hits for "Pebble smartwatch").
- `obsidian-mcp@2` logs a non-fatal `[LEGACY_MCP_PROTOCOL]` warning because `mcp-proxy` (built on the
  `mcp<2` SDK) negotiates the older 2025-era `initialize` handshake rather than `2026-07-28`. Harmless
  and expected — do **not** add `--legacy reject` to `obsidian-mcp`'s args, since that would make it
  reject `mcp-proxy`'s connection outright.
- **An existing SearXNG is already running** (`n8n-searxng-1`, part of n8n's own sandbox stack) with
  `formats: [html, json]` already enabled in `settings.yml` and reachable only via the internal
  `n8n_n8n_internal` Docker network (DNS alias `searxng`, no published host port) — i.e. already
  isolated the way this project wants a dedicated `searxng` service to be. This makes reuse — rather
  than standing up a second, separate SearXNG — worth strongly considering when `searxng-service`
  executes; deferred to that todo since it also needs to weigh shared-resource/blast-radius concerns.
  **Resolved in `searxng-service` (see the table below): not reused** — turned out to be an internal
  piece of n8n's own sandbox feature, not a general-purpose instance.

## Workflow logic (n8n)

**✅ Built and imported (`n8n-workflow-trigger`, `n8n-workflow-agent`, 2026-08-25)** —
`n8n/workflows/pebble-index-research-agent.json`, validated by actually importing it into the real
`n8n` instance (`n8n import:workflow`) and exporting it back out to confirm every node/connection
round-tripped intact. Not yet activated or e2e-tested against a real note — that needs an LLM
credential attached in the n8n UI first (deliberately left for the user to add post-import, see
`docs/SETUP.md` Phase 3).

1. **Local File Trigger** (`Watch Index Inbox`) — watches `/vault-mirror/Index Inbox` (the vault mirror,
   bind-mounted **read-only** into the `n8n` container itself — a real edit to n8n's own shared
   `compose.yml`, applied and validated live) for `add` events.
2. **Read Note From Disk** → **Extract Note Text** — reads the new file directly off the mounted mirror
   and extracts its plain text (`n8n-nodes-base.readWriteFile` + `n8n-nodes-base.extractFromFile`),
   rather than round-tripping through `obsidian_read_note` for the very note that just triggered the
   workflow — one fewer tool call, and n8n already needs read access to that path for the trigger
   itself.
3. **Prepare Agent Input** — computes the note's vault-*relative* path (`notePath`, stripping the
   `/vault-mirror/` prefix n8n sees down to what `mcp-obsidian`'s own `/vault` mount expects) alongside
   the extracted `noteText`, so the two mounts' different container-side paths for the same host
   directory don't leak into the agent's tool calls.
4. **Research Agent** (`@n8n/n8n-nodes-langchain.agent`) — system prompt instructs the model to:
   - Identify the core research question(s) from the transcript (often a fragment — infer intent).
   - Call the `search` tool (`MCP: mcp-searxng`, possibly multiple times) to gather sources.
   - Synthesize findings into a well-structured note with a clear, relevant title and 2-5 tags.
   - Call `obsidian_create_note` (`MCP: obsidian-mcp`) to save the result into `Research/`, with YAML
     frontmatter (`tags`, `source` — the original note's vault-relative path, `created`).
   - Call `obsidian_edit_note` on the original note to append a backlink to the new research note.
5. **`livesync-cli` daemon** picks up the new/edited files via its filesystem watcher and pushes them
   through MinIO, where they sync back down to the phone/desktop automatically.

## Open questions / spikes

| Spike | Question | Status |
|---|---|---|
| `spike-livesync-s3` | Does `livesync-cli daemon` work cleanly against the existing MinIO remote + passphrase, in both directions, unattended? | ✅ Validated — see findings above. Remote uses Journal Sync (not CouchDB); Setup URI + one-time `unlock-remote` bootstraps a new device; `daemon` mode confirmed bidirectional. |
| `spike-mcp-bridge` | Does `mcp-proxy` reliably bridge `obsidian-mcp` and `mcp-searxng` to SSE endpoints n8n's MCP Client Tool node can use? | ✅ Validated — see findings above. Must use the real `sparfenyuk/mcp-proxy` (Python, not the unrelated `npx mcp-proxy` npm package), pin `mcp<2`, pass `--pass-environment`, and install `mcp-searxng` from source (PyPI is stale). Both bridges round-tripped real tool calls from the actual `n8n` container. |
| `server-base-setup` | Is Docker Engine + Compose ready on `home_server`, and what's the right network/secrets layout? | ✅ Validated — Docker 29.7.2 / Compose v5.5.0 confirmed. Project cloned to `/data/projects/pebble-index-research-agent/repo`. `mcp-obsidian`/`mcp-searxng` join the existing `n8n_n8n_internal` network (external); a new `pebble-agent-internal` network isolates `searxng`. Real `.env` populated on the server from the already-bootstrapped `livesync-settings.json`. |
| `searxng-service` | Reuse the already-running `n8n-searxng-1`, or stand up a dedicated instance? | ✅ Validated (2026-08-25) — **not** reused. `n8n-searxng-1` turned out to be an internal piece of n8n's own `instance-ai` sandbox feature (chained to `sandbox-api`/a privileged Docker-in-Docker `sandbox-runner-1`), confirmed stopped on the real server whenever that sandbox is idle — an unsuitable, undocumented dependency. Deployed the dedicated `searxng` service instead; full stack (`searxng`, `mcp-obsidian`, `mcp-searxng`) built, started, and round-tripped real MCP tool calls + a live JSON search on `home_server`, with both SSE endpoints confirmed reachable from the real `n8n` container. Two real gotchas hit along the way — see `docs/TROUBLESHOOTING.md`. |
| `n8n-workflow-trigger` / `n8n-workflow-agent` | Can the actual trigger → agent → tools workflow be built with standard n8n nodes and imported cleanly? | ✅ Fully validated end-to-end (2026-08-25). Built with two real infra changes on top of the initial import: the Local File Trigger node needs the vault mirror bind-mounted **into n8n's own container** (a shared `compose.yml` edit, done with the user's go-ahead), and two n8n security defaults (`NODES_EXCLUDE`, `N8N_RESTRICT_FILE_ACCESS_TO`) needed explicit overrides or the trigger silently never activates — see `docs/TROUBLESHOOTING.md` for exactly what that looked like in the logs, since neither surfaced as an import/publish/UI error. Sourced exact node `type`/`typeVersion`/parameter names directly from the installed node definitions inside the running `n8n` container rather than guessing. Model backend switched to **OpenRouter** (`@n8n/n8n-nodes-langchain.lmChatOpenRouter`) per explicit user preference for free choice of underlying model over a locked-in provider. **Real e2e test passed**: a note dropped into `Index Inbox/` triggered the workflow, which searched the web (`poolside/laguna-s-2.1:free` via OpenRouter) and wrote a well-structured, correctly-tagged note into `Research/` plus a backlink on the original — full round trip confirmed on the live server. Sync-back to the phone via `livesync-cli` is a separate, not-yet-validated open issue (see `docs/TROUBLESHOOTING.md`). |

## Deployment topology

Everything below runs as Docker containers on the existing headless Ubuntu server (`docker-ce` +
`docker-compose-plugin`, **no Docker Desktop**, confirmed Docker 29.7.2 / Compose v5.5.0):

- `minio` (already running)
- `n8n` (already running — gains a read/write bind mount to the vault-mirror folder)
- `livesync-cli` (new, `daemon` mode) — no explicit network needed (volumes + outbound HTTPS only)
- `searxng` (new, dedicated to this project — deliberately not the pre-existing `n8n-searxng-1`, see
  `searxng-service` above) — on the project's own `pebble-agent-internal` network only, not reachable by
  n8n or the host directly
- `mcp-obsidian` (new — `obsidian-mcp` + `mcp-proxy`, mounts the vault-mirror folder) — on n8n's existing
  `n8n_n8n_internal` network (external), so n8n's MCP Client Tool node can reach it
- `mcp-searxng` (new — `MCP-searxng` + `mcp-proxy`) — bridges both `n8n_n8n_internal` (reachable by n8n)
  and `pebble-agent-internal` (reachable by `searxng`)

**Project directory on the server:** `/data/projects/pebble-index-research-agent/repo` (a plain `git
clone` of this repo, re-`git pull`-able on future updates). The real `docker/.env` (gitignored, MinIO
creds + SearXNG config) lives alongside it there — never in this repo. See `docs/SETUP.md` Phase 0.5
for the exact bootstrap commands and the reasoning behind the two-network split.

See [`docker/docker-compose.yml`](../docker/docker-compose.yml) for the current (in-progress) service
definitions.

