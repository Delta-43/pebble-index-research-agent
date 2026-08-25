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

## Current state (as of this writing)

**The full `docker/docker-compose.yml` stack (`livesync-cli`, `searxng`, `mcp-obsidian`, `mcp-searxng`)
is deployed and validated on the real server (`home_server`, hostname `delta-server`)**, and the n8n
workflow itself (`n8n/workflows/pebble-index-research-agent.json`) is built and imported into the real
`n8n` instance — round-tripped clean via `import:workflow`/`export:workflow`, vault mirror bind-mounted
into n8n's own container for the trigger. **Not yet done: attaching a real LLM credential and
activating it** (deliberately left for the user — see `docs/SETUP.md` Phase 3 steps 3-4), so no
end-to-end test against a real note has run yet. Sessions now run directly on `home_server` (no `ssh
home_server` hop needed) — see `docs/ARCHITECTURE.md`/`docs/SETUP.md`/`docs/TROUBLESHOOTING.md` for the
real findings behind every service, and `docs/TROUBLESHOOTING.md` in particular for gotchas worth
re-checking before assuming anything "just works" (Compose's `external: true` network handling,
SearXNG's `secret_key` startup precondition, the `npx mcp-proxy` impostor package, n8n's undocumented
required top-level workflow `id`, etc.). When building/editing n8n workflow JSON, don't guess node
schemas — read them from `.../dist/node-definitions/nodes/**/v<N>.ts` inside the running `n8n`
container (see `docs/TROUBLESHOOTING.md`).

Track work via the project's todo list (ask the user for the current SQL-backed todo state, or check
for a synced task list if one has been added to this repo). As of this writing, the phase order is:

1. `spike-livesync-s3` — ✅ done
2. `spike-mcp-bridge` — ✅ done
3. `server-base-setup` — ✅ done
4. `vault-mirror-service`, `searxng-service` (parallel) — ✅ both done (searxng-service deliberately did
   **not** reuse the pre-existing `n8n-searxng-1`; see `docs/ARCHITECTURE.md`)
5. `mcp-obsidian-service`, `mcp-searxng-service` (parallel) — ✅ both done, deployed as real standing
   compose services (not just spike scratch containers) and re-validated end-to-end
6. `n8n-workflow-trigger`, then `n8n-workflow-agent` — ✅ both done (workflow built, imported,
   round-tripped; LLM credential + activation deliberately left for the user, see `docs/SETUP.md`)
7. `e2e-testing` — **next up**, blocked on the user attaching a real LLM credential and activating
8. `docs-repo` (fill in the still-pending doc sections)
9. `publish-github` (repo already exists and is public: `Delta-43/pebble-index-research-agent`; this
   step is about final polish/release, not initial creation)

## Environment / access notes

- The target deployment server is a headless Ubuntu machine, historically reachable over SSH as
  `home_server` (an SSH config alias). Some agent sessions run directly on that server already (check
  `hostname` — `delta-server` means you're on it); in that case skip the `ssh home_server` hop entirely
  and run `docker`/`git` commands directly.
- MinIO is already running on that same server, backing the user's Obsidian **Self-hosted LiveSync**
  plugin.
- n8n is already running and reachable from that server.
- Docker on that server should be plain `docker-ce` + `docker-compose-plugin` — **no Docker Desktop**,
  and nothing in this project should assume it's available.

## Key decisions already made (don't re-litigate without new evidence)

- **Vault mirror mechanism**: `vrtmrz/obsidian-livesync`'s official CLI (`src/apps/cli`, aka
  `livesync-cli`), run in `daemon` mode, mirrors the vault to plain `.md` files on disk against the same
  MinIO/S3 remote already used by the phone. This was chosen over running headless Obsidian (Electron)
  and over parsing the MinIO bucket directly (LiveSync doesn't store plain files there — see
  `docs/ARCHITECTURE.md`).
- **Obsidian tool for the agent**: `StevenStavrakis/obsidian-mcp` (v2) — filesystem-based, no REST API
  plugin or running Obsidian process required. Operates directly on the mirrored vault directory.
- **Web research tool**: self-hosted **SearXNG** + `SecretiveShell/MCP-searxng`, chosen over a full
  browser-automation MCP (Playwright) and over paid search APIs (Tavily/Brave), per explicit user
  preference for simplicity and self-hosting.
- **stdio→HTTP bridge**: both MCP servers above are stdio-based; `sparfenyuk/mcp-proxy` wraps each as
  an SSE endpoint for n8n's built-in **MCP Client Tool** node. This keeps every tool as an independent
  container reachable over the network, rather than bundling node/python tooling into the n8n image.
- **LLM**: [OpenRouter](https://openrouter.ai/) (`@n8n/n8n-nodes-langchain.lmChatOpenRouter`), a single
  API key with free choice of underlying model — not a local/Ollama model, and not a single locked-in
  provider — per explicit user preference for customizability. The node's `model` parameter is a plain
  string (e.g. `openai/gpt-5-mini`, `anthropic/claude-sonnet-4.6`, `google/gemini-3.1-pro-preview`), so
  swapping models never requires touching the node graph — see `docs/SETUP.md` Phase 3.
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
