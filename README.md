# Pebble Index Research Agent

Turn a voice note captured on your [Core Devices Pebble Index 01](https://repebble.com/index) ring into an
auto-researched, auto-tagged note in your Obsidian vault — no manual copy/paste required.

> **Status: 🚧 Work in progress.** This repo is being built and documented in the open. See
> [Project Status](#project-status) for what's validated vs. still in progress.

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
     n8n AI Agent (cloud LLM) ──uses──► MCP: obsidian-mcp   (read / write / tag notes)
                                   └──uses──► MCP: mcp-searxng (web research via self-hosted SearXNG)
                                            │
     New research note (title + tags) written back into the vault mirror
                                            │
     livesync-cli syncs it back through MinIO → appears on your phone/desktop
```

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

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design and open questions, and
[`docs/SETUP.md`](docs/SETUP.md) for the step-by-step install guide (filled in as each phase is validated).

- [ ] Validate `livesync-cli` daemon mode against a MinIO/S3 remote
- [ ] Validate stdio→SSE bridging for both MCP servers
- [ ] Docker Compose stack for the server
- [ ] n8n workflow (trigger → agent → tools → save note)
- [ ] End-to-end test with a real ring recording
- [ ] Full documentation pass

## Prerequisites

- A Core Devices Pebble Index 01 ring + the [Pebble mobile app](https://github.com/coredevices/mobileapp)
- An Obsidian vault using the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin,
  synced through your own MinIO (or other S3-compatible / CouchDB) instance
- A headless Linux server with Docker Engine + the Compose plugin (no Docker Desktop)
- An existing n8n instance (self-hosted) with access to that server
- An API key for a cloud LLM (OpenAI / Anthropic / Gemini)

## License

[MIT](LICENSE)
