# Pebble Index Research Agent

Turn a voice note captured on your [Core Devices Pebble Index 01](https://repebble.com/index) ring into an
auto-researched, auto-tagged note in your Obsidian vault — no manual copy/paste required.

> **Status: core pipeline validated end-to-end on a real deployment** — trigger, agent, web research, and
> sync-back all confirmed working (see [Project Status](#project-status)). Not yet tested with an actual
> ring recording (only a manually-dropped note so far).

**→ [`docs/SETUP.md`](docs/SETUP.md) has the full step-by-step deployment guide.** This README covers
the *what* and *why*; `docs/SETUP.md` is what you actually follow to deploy it yourself.

## How it works

```
Ring → Pebble App (phone) → transcribed note saved in Obsidian vault
     → Self-hosted LiveSync plugin → MinIO (S3-compatible) bucket
                                            │
                    [ headless Ubuntu server, Docker Engine — no Docker Desktop required ]
                                            │
     livesync-cli (daemon mode) ──────► plain .md mirror folder on disk (bidirectional)
                                            │
     n8n Local File Trigger watches the ring-notes subfolder
                                            │
     n8n AI Agent (OpenRouter, any model) ──uses──► MCP: obsidian-mcp   (read / write / tag notes)
                                       └──uses──► MCP: mcp-searxng (web research via self-hosted SearXNG)
                                            │
     New research note (title + tags) written back into the vault mirror
                                            │
     livesync-cli syncs it back through MinIO → appears on your phone/desktop
```

> The "ring-notes subfolder" name and n8n's Docker network name are specific to *this* project's own
> deployment (`Index Inbox/` and `n8n_n8n_internal`, respectively) — yours will likely be named
> differently. `docs/SETUP.md` shows how to find/set your own for both.

## Why this design

- **No Docker Desktop needed** — everything runs on a headless Ubuntu server via plain `docker-ce` +
  the `compose` plugin.
- **No Obsidian REST API / no running the Obsidian Electron app on the server** — the vault is mirrored
  to plain Markdown files on disk using [`livesync-cli`](https://github.com/vrtmrz/obsidian-livesync/tree/main/src/apps/cli),
  the official headless companion to the *Self-hosted LiveSync* plugin.
- **Fully self-hostable research** — web search goes through a self-hosted [SearXNG](https://github.com/searxng/searxng)
  instance via an MCP server, so no third-party search API key is required.
- **Standard n8n building blocks** — trigger, AI Agent node, and MCP Client Tool nodes; no custom code
  needed inside n8n itself.

## Components

| Component | Project | Role |
|---|---|---|
| Vault mirror | [`vrtmrz/obsidian-livesync`](https://github.com/vrtmrz/obsidian-livesync) (`src/apps/cli`) | Headless daemon that keeps a plain-Markdown mirror of the vault in sync with the same MinIO/S3 (or CouchDB) remote used by the Self-hosted LiveSync plugin |
| Object storage | [MinIO](https://min.io/) | S3-compatible remote for Self-hosted LiveSync (assumed already running) |
| Orchestration | [n8n](https://n8n.io/) | Local File Trigger + AI Agent workflow (assumed already running) |
| Obsidian tools | [`StevenStavrakis/obsidian-mcp`](https://github.com/StevenStavrakis/obsidian-mcp) | MCP server for reading/writing/tagging notes directly on disk |
| Web research | [`SecretiveShell/MCP-searxng`](https://github.com/SecretiveShell/MCP-searxng) + [SearXNG](https://github.com/searxng/searxng) | MCP server exposing web search backed by a self-hosted meta search engine |
| stdio→HTTP bridge | [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) | Exposes the (stdio) MCP servers above as SSE endpoints n8n can call |

## Project status

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design and rationale, and
[`docs/SETUP.md`](docs/SETUP.md) for the step-by-step install guide.

- [x] Validate `livesync-cli` daemon mode against a MinIO/S3 remote
- [x] Validate stdio→SSE bridging for both MCP servers
- [x] Docker Compose stack for the server (`livesync-cli`, dedicated `searxng`, `mcp-obsidian`,
      `mcp-searxng` — deployed and round-tripped real tool calls/searches on the real server)
- [x] n8n workflow (trigger → agent → tools → save note) — built, imported, activated, and confirmed
      working end-to-end on the real n8n instance, using OpenRouter (any underlying model, one API key)
- [x] End-to-end test — agent half: a real dropped note triggered a real web search and produced a
      real, correctly-tagged research note with a backlink, using a free OpenRouter model
- [x] End-to-end test — sync-back half: confirmed `livesync-cli` picks up and pushes new/edited files
      to MinIO correctly, and that this works with **zero Obsidian instances live on any device** (see
      `docs/TROUBLESHOOTING.md`)
- [ ] Test with a real ring recording (so far tested with a manually-dropped note)
- [x] Full documentation pass — repo generalized for other users to replicate (parameterized network
      name, called out vault-specific values, rewrote `docs/SETUP.md` as a linear step-by-step guide)

## Prerequisites

- A Core Devices Pebble Index 01 ring + the [Pebble mobile app](https://github.com/coredevices/mobileapp)
- An Obsidian vault using the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin,
  synced through your own MinIO (or other S3-compatible / CouchDB) instance
- A headless Linux server with Docker Engine + the Compose plugin (no Docker Desktop)
- An existing n8n instance (self-hosted) with access to that server
- An [OpenRouter](https://openrouter.ai/) API key — one key, free choice of underlying model

## License

[MIT](LICENSE)
