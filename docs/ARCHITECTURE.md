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

The n8n workflow's **AI Agent** node (backed by a cloud LLM — OpenAI/Anthropic/Gemini) is given two MCP
tool servers via n8n's **MCP Client Tool** node:

1. **`obsidian-mcp`** (`StevenStavrakis/obsidian-mcp`) — operates directly on the mirrored vault
   directory (no Obsidian process, no REST API plugin required). Exposes tools like
   `obsidian_read_note`, `obsidian_create_note`, `obsidian_search_vault`, `obsidian_add_tags`, etc.
2. **`mcp-searxng`** (`SecretiveShell/MCP-searxng`) — exposes a `search` tool backed by a self-hosted
   **SearXNG** meta search instance, so no third-party search API key is needed.

Both are **stdio** MCP servers by design. n8n's built-in MCP Client Tool node expects an HTTP/SSE
endpoint, so each is wrapped with **`mcp-proxy`** (`sparfenyuk/mcp-proxy`), which turns any stdio MCP
server into an SSE endpoint with one command:

```
mcp-proxy --port <port> -- <stdio command>
```

This keeps every tool as an independent, network-reachable container — nothing needs to be installed
inside the n8n container itself. This bridging approach is the second thing to validate
(`spike-mcp-bridge`).

## Workflow logic (n8n)

1. **Local File Trigger** — new `.md` appears in the watched subfolder.
2. **Read note** — read the raw transcript text (either directly via n8n's file read, or via
   `obsidian_read_note`).
3. **AI Agent** — system prompt instructs the model to:
   - Summarize the note and identify the core research question(s).
   - Call the SearXNG `search` tool (possibly multiple times) to gather sources.
   - Synthesize findings into a well-structured note with a clear, relevant title.
   - Choose relevant tags.
   - Call `obsidian_create_note` to save the result into a `Research/` folder, with YAML frontmatter
     (`tags`, a link back to the source note, creation date).
   - Optionally call `obsidian_edit_note` on the original transcript to add a backlink to the new
     research note.
4. **`livesync-cli` daemon** picks up the new/edited files via its filesystem watcher and pushes them
   through MinIO, where they sync back down to the phone/desktop automatically.

## Open questions / spikes

| Spike | Question | Status |
|---|---|---|
| `spike-livesync-s3` | Does `livesync-cli daemon` work cleanly against the existing MinIO remote + passphrase, in both directions, unattended? | ✅ Validated — see findings above. Remote uses Journal Sync (not CouchDB); Setup URI + one-time `unlock-remote` bootstraps a new device; `daemon` mode confirmed bidirectional. |
| `spike-mcp-bridge` | Does `mcp-proxy` reliably bridge `obsidian-mcp` and `mcp-searxng` to SSE endpoints n8n's MCP Client Tool node can use? | Pending |

## Deployment topology

Everything below runs as Docker containers on the existing headless Ubuntu server (`docker-ce` +
`docker-compose-plugin`, **no Docker Desktop**):

- `minio` (already running)
- `n8n` (already running — gains a read/write bind mount to the vault-mirror folder)
- `livesync-cli` (new, `daemon` mode)
- `searxng` (new)
- `mcp-obsidian` (new — `obsidian-mcp` + `mcp-proxy`, mounts the vault-mirror folder)
- `mcp-searxng` (new — `MCP-searxng` + `mcp-proxy`, network-only access to `searxng`)

See [`docker/docker-compose.yml`](../docker/docker-compose.yml) for the current (in-progress) service
definitions.
