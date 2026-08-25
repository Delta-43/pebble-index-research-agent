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
files — it replicates its internal chunked/PouchDB-style document model as objects. That means you
can't just point a file-watcher at the MinIO bucket and expect readable Markdown.

## Getting a real, plain-Markdown mirror on the server

`vrtmrz/obsidian-livesync` ships a companion CLI (`src/apps/cli`, package name `livesync-cli`) that
implements the same sync protocol as the Obsidian plugin, without needing Obsidian (or any Electron/GUI)
running:

- `livesync-cli <db-path> daemon --vault <mirror-path>` performs an initial mirror scan, then
  continuously syncs in both directions:
  - **remote → local filesystem**: via the CouchDB `_changes` feed (or polling, `--interval N`)
  - **local filesystem → remote**: via `chokidar` file watching
- It ships with an official `Dockerfile` and a systemd unit + `install.sh` for non-Docker installs.
- Its `util/minio-init.sh` / `minio-stop.sh` scripts in the repo indicate S3/MinIO remotes are part of
  its own test matrix, in addition to the more thoroughly-documented CouchDB path.

**This is the load-bearing assumption for the whole project and the first thing to validate**
(see `spike-livesync-s3` below) — specifically, whether `remote-add`/`setup` cleanly accepts a MinIO
endpoint + the same encryption passphrase used by the phone's plugin, and whether `daemon` mode keeps
the mirror folder live in both directions without manual intervention.

Once validated, the server ends up with a directory (e.g. `/srv/vault-mirror/`) that always mirrors the
real vault as plain files — this is what n8n and the Obsidian MCP server both operate on.

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
| `spike-livesync-s3` | Does `livesync-cli daemon` work cleanly against the existing MinIO remote + passphrase, in both directions, unattended? | Pending |
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
