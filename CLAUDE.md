# CLAUDE.md

Guidance for Claude Code (or any AI coding agent) picking up work on this repository.

## What this project is

An automated research pipeline: a voice note recorded on a **Core Devices Pebble Index 01** ring is
transcribed by the [Pebble mobile app](https://github.com/coredevices/mobileapp) and saved into an
Obsidian vault. This project watches for that new note, has an **n8n AI Agent** research the topic on
the web, and writes a titled, tagged "research note" back into the same vault — fully self-hosted, no
Docker Desktop, no paid Obsidian Sync, no third-party search API key required.

Read `README.md` first, then `docs/ARCHITECTURE.md` for the full design rationale — don't re-derive the
architecture from scratch, it's already been researched and decided (see "Key decisions" below).

## Current state (as of this writing, 2026-08-25)

**4 of 12 phases are done and merged to `main` (PRs #1, #2, #3). Real infrastructure is running on
`home_server` right now.** Don't re-derive or re-validate what's already confirmed below — build on it.

Done:

1. ✅ `spike-livesync-s3` — `livesync-cli` validated against the real MinIO/S3 remote. Confirmed the
   remote uses LiveSync's E2EE **Journal Sync** mode (not CouchDB replication, not plain files — this
   *refines* the original architecture assumption, see `docs/ARCHITECTURE.md`).
2. ✅ `spike-mcp-bridge` — `sparfenyuk/mcp-proxy` validated bridging both `obsidian-mcp` and
   `mcp-searxng` (stdio) to SSE, reachable from the real running `n8n` container. Several sharp edges
   found and documented (see "Known gotchas" below) — read `docs/TROUBLESHOOTING.md` before touching
   these services.
3. ✅ `server-base-setup` — Docker Engine 29.7.2 + Compose v5.5.0 confirmed on `home_server`. Project
   checked out at `/data/projects/pebble-index-research-agent/repo` on the server. Real `docker/.env`
   exists **on the server only** (gitignored, never committed) with MinIO creds + vault-mirror paths.
   Two Docker networks wired into `docker-compose.yml`: `n8n_n8n_internal` (external, shared with the
   existing n8n container) and `pebble-agent-internal` (project-owned, isolates `searxng`).
4. ✅ `vault-mirror-service` — `livesync-cli` is **actually running right now** on `home_server` as a
   persistent `daemon`-mode container, bind-mounted (not anonymous volumes) at `${VAULT_MIRROR_DATA_PATH}`
   / `${VAULT_MIRROR_PATH}` from `docker/.env`, confirmed live bidirectional sync (local create/delete
   ↔ remote, ~2s latency). Verify with `ssh home_server 'cd /data/projects/pebble-index-research-agent/repo/docker && docker compose ps'`.

Not yet done, in dependency order (query the repo's todo list for exact status/descriptions — this
session used a SQL-backed todo/todo_deps table that may or may not be replicated where you're working;
if not, recreate it from this list):

5. `searxng-service` — depends on `server-base-setup` (done). **Ready to start.** `docker-compose.yml`
   already has a `searxng` service defined and building cleanly, just not deployed yet. NOTE: an
   existing `n8n-searxng-1` container is *already running* on the server (part of n8n's own stack) with
   JSON format already enabled, reachable only via the internal n8n network — decide whether to reuse
   that instead of standing up a second one before deploying.
6. `mcp-obsidian-service` — depends on `vault-mirror-service` (done). **Ready to start.**
   `docker/mcp-obsidian/Dockerfile` already exists and was smoke-tested during the spike, but isn't
   deployed as a persistent service yet.
7. `n8n-workflow-trigger` — depends on `vault-mirror-service` (done). **Ready to start.**
8. `mcp-searxng-service` — depends on `searxng-service` (not done). Blocked until #5.
9. `n8n-workflow-agent` — depends on `mcp-obsidian-service`, `mcp-searxng-service`, `n8n-workflow-trigger`.
   Blocked until #6, #7, #8.
10. `e2e-testing` — depends on `n8n-workflow-agent`.
11. `docs-repo` — fill in remaining pending doc sections once everything works end-to-end.
12. `publish-github` — repo already exists and is public (`Delta-43/pebble-index-research-agent`); this
    step is about final polish/release (screenshots, demo), not initial creation.

## Known gotchas (read before touching MCP services)

- `npx -y mcp-proxy` resolves to the **wrong package** (`punkpeye/mcp-proxy`, npm). The real
  `sparfenyuk/mcp-proxy` is a **Python** package: `pip install mcp-proxy`.
- `mcp-proxy` 0.12.0 requires `mcp<2` pinned — breaks silently against `mcp` 2.x despite a loose
  constraint.
- `mcp-proxy` needs `--pass-environment` explicitly to forward env vars (e.g. `SEARXNG_URL`) into the
  wrapped stdio child process — not automatic.
- `SecretiveShell/MCP-searxng`'s **PyPI** package (0.1.0) is stale and incompatible with current
  SearXNG's JSON schema (`number_of_results` field mismatch) — install from **git source** instead.
- `obsidian-mcp@2` requires a pre-existing `.obsidian/` directory in the vault path. Journal Sync does
  not replicate this directory — create it once: `mkdir -p "$VAULT_MIRROR_PATH/.obsidian"`.
- The official `livesync-cli` Docker image writes files as **root** — anything else reading/writing the
  vault mirror needs to tolerate root-owned files/subdirectories.
- Full details and exact commands for all of the above: `docs/TROUBLESHOOTING.md`.

## Security note

During `server-base-setup`, a debugging command's redaction regex failed once and printed real MinIO
access key + secret key into that session's transcript (never committed, never shared externally, but
visible in a conversation log). The user was notified and chose to rotate those credentials manually
themselves. **If you are continuing this project and the MinIO credentials in `docker/.env` on
`home_server` no longer work, that's expected — check with the user for the rotated credentials rather
than assuming the ones referenced in old session transcripts still work.**

## Environment / access notes

- The target deployment server is a headless Ubuntu machine reachable over SSH as `home_server`
  (an SSH config alias — do not ask the user for an IP; just `ssh home_server`).
- MinIO is already running on that same server, backing the user's Obsidian **Self-hosted LiveSync**
  plugin (Journal Sync mode), bucket `obsidian-bucket`.
- n8n is already running and reachable from that server, with its own Docker network
  `n8n_n8n_internal` (external to this project — joined by `mcp-obsidian`/`mcp-searxng`, not owned by
  this repo) and its own existing SearXNG sidecar (`n8n-searxng-1`, see `searxng-service` note above).
- Docker on that server is plain `docker-ce` + `docker-compose-plugin` (29.7.2 / v5.5.0 confirmed) —
  **no Docker Desktop**, and nothing in this project should assume it's available.
- This project's deployment checkout lives at `/data/projects/pebble-index-research-agent/repo` on
  `home_server`; the compose project is `/data/projects/pebble-index-research-agent/repo/docker`. The
  real `docker/.env` there is gitignored and was bootstrapped from the already-paired
  `livesync-settings.json` — don't hand-type credentials, and don't assume the values referenced in
  old session transcripts still work (see "Security note" above).

## Key decisions already made (don't re-litigate without new evidence)

- **Vault mirror mechanism**: `vrtmrz/obsidian-livesync`'s official CLI (`src/apps/cli`, aka
  `livesync-cli`), run in `daemon` mode, mirrors the vault to plain `.md` files on disk against the same
  MinIO/S3 remote already used by the phone. **Confirmed and running**: the remote uses LiveSync's E2EE
  **Journal Sync** mode specifically (`.jsonl.gz` chunks + milestone doc in `obsidian-bucket`) — not
  CouchDB replication, and not raw files. This was chosen over running headless Obsidian (Electron) and
  over parsing the MinIO bucket directly (LiveSync doesn't store plain files there — see
  `docs/ARCHITECTURE.md`). Bootstrap uses the plugin's own **Setup URI** (`setup` command) rather than
  hand-typed S3 credentials.
- **Obsidian tool for the agent**: `StevenStavrakis/obsidian-mcp` (v2) — filesystem-based, no REST API
  plugin or running Obsidian process required. Operates directly on the mirrored vault directory.
- **Web research tool**: self-hosted **SearXNG** + `SecretiveShell/MCP-searxng`, chosen over a full
  browser-automation MCP (Playwright) and over paid search APIs (Tavily/Brave), per explicit user
  preference for simplicity and self-hosting.
- **stdio→HTTP bridge**: both MCP servers above are stdio-based; `sparfenyuk/mcp-proxy` wraps each as
  an SSE endpoint for n8n's built-in **MCP Client Tool** node. This keeps every tool as an independent
  container reachable over the network, rather than bundling node/python tooling into the n8n image.
- **LLM**: a cloud API (OpenAI/Anthropic/Gemini) configured as an n8n credential — not a local/Ollama
  model — per explicit user preference.
- **Trigger**: n8n's built-in **Local File Trigger** node, watching the ring-notes subfolder inside the
  mirrored vault directory (mounted into the n8n container).

If you find any of the above is wrong once tested against real infrastructure, update
`docs/ARCHITECTURE.md` and this file's "Key decisions" section together, and record the correction in
`docs/TROUBLESHOOTING.md`.

## Working conventions for this repo

- This repo is meant to be **published documentation of a real, working setup**, not just working code.
  Whenever you get something working, update `docs/SETUP.md` (check off the relevant step, replace
  `_Pending_` placeholders with real instructions) and `docs/TROUBLESHOOTING.md` (record any real
  gotchas hit along the way) in the same change.
- Keep `docker/docker-compose.yml` deployable as a standalone file/overlay — don't assume it's the only
  compose file on the server (the user's existing `n8n`/`minio` services live elsewhere).
- Never commit real secrets. `docker/.env.example` documents required variables; the real `.env` is
  gitignored.
- Once the n8n workflow is built, export it as JSON into `n8n/workflows/` so it's versioned and
  reproducible for anyone following the guide.
- Prefer validating assumptions against the real server (`ssh home_server`) over trusting documentation
  or web search summaries — several details in this space (e.g. exact CLI flags, MCP bridging behavior)
  were not fully verifiable ahead of time and are flagged as spikes for a reason.
