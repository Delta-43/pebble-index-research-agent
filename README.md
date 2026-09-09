<h1 align="center">Pebble Index Research Agent</h1>

<p align="center">
  <i>Turn a voice note captured on your <a href="https://repebble.com/index">Core Devices Pebble Index 01</a>
  ring into an auto-researched, auto-tagged note in your Obsidian vault — no manual copy/paste required.</i>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL%20v3-blue.svg?style=plastic" alt="License: AGPL v3"></a>
  <img src="https://img.shields.io/badge/Maintenance-yes-green.svg?style=plastic" alt="Maintenance">
  <a href="https://github.com/Delta-43/pebble-index-research-agent/commits/main"><img src="https://img.shields.io/github/last-commit/Delta-43/pebble-index-research-agent.svg?style=plastic" alt="GitHub last commit"></a>
</p>

<p align="center">
  <a href="docker/docker-compose.yml"><img src="https://img.shields.io/badge/docker-compose-2496ED.svg?style=plastic&logo=docker&logoColor=white" alt="Docker Compose"></a>
  <a href="https://n8n.io/"><img src="https://img.shields.io/badge/built%20with-n8n-EA4B71.svg?style=plastic" alt="Built with n8n"></a>
  <a href="https://github.com/Delta-43?tab=packages&repo_name=pebble-index-research-agent"><img src="https://img.shields.io/badge/image-ghcr.io-2496ED.svg?style=plastic&logo=docker&logoColor=white" alt="Published on GHCR"></a>
  <a href="https://github.com/Delta-43/pebble-index-research-agent/actions/workflows/docker-publish.yml"><img src="https://img.shields.io/github/actions/workflow/status/Delta-43/pebble-index-research-agent/docker-publish.yml?branch=main&label=docker%20publish&style=plastic" alt="docker-publish CI"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-validated%20end--to--end-brightgreen.svg?style=plastic" alt="Status: validated end-to-end">
</p>

<p align="center">
  <a href="#-how-it-works">How it works</a> •
  <a href="#-why-this-design">Why this design</a> •
  <a href="#-components">Components</a> •
  <a href="#-project-status">Status</a> •
  <a href="#-project-structure">Structure</a> •
  <a href="#-documentation">Documentation</a> •
  <a href="#-tech-stack">Tech Stack</a> •
  <a href="#-prerequisites">Prerequisites</a>
</p>

> [!TIP]
> **[`docs/SETUP.md`](docs/SETUP.md) has the full step-by-step deployment guide.** This README covers
> the *what* and *why*; `docs/SETUP.md` is what you actually follow to deploy it yourself.

---

## 🎙️ How it works

<p align="center">
  <img src="docs/images/pipeline.svg" alt="Pipeline diagram: a ring recording flows through the Pebble app, Self-hosted LiveSync, and MinIO to a headless server, where a shared vault-mirror hub feeds an n8n trigger and agent, which researches the topic via SearXNG and writes a tagged note back into the same vault mirror." width="640">
</p>

<p align="center"><sub>New notes flow back through the same MinIO sync path to your phone/desktop
automatically — no device needs to be online at the same time as any other (see
<a href="docs/TROUBLESHOOTING.md#livesync-cli--vault-mirror-spike-livesync-s3">TROUBLESHOOTING.md</a>
for why).</sub></p>

> [!NOTE]
> The "ring-notes subfolder" name and n8n's Docker network name are specific to *this* project's own
> deployment (`Index Inbox/` and `n8n_n8n_internal`, respectively) — yours will likely be named
> differently. `docs/SETUP.md` shows how to find/set your own for both.

Every research note gets a clear title, 2-5 topical tags, and two fixed tags applied to every note this
workflow creates — `#interests` and `#questions` — plus a `source` link back to the original voice note.
Customizable (see [Reconfiguring things later](docs/SETUP.md#reconfiguring-things-later)).

## 🧩 Why this design

- **No Docker Desktop needed** — everything runs on a headless Ubuntu server via plain `docker-ce` +
  the `compose` plugin.
- **No Obsidian REST API / no running the Obsidian Electron app on the server** — the vault is mirrored
  to plain Markdown files on disk using [`livesync-cli`](https://github.com/vrtmrz/obsidian-livesync/tree/main/src/apps/cli),
  the official headless companion to the *Self-hosted LiveSync* plugin.
- **Fully self-hostable research** — web search goes through a self-hosted [SearXNG](https://github.com/searxng/searxng)
  instance via an MCP server, so no third-party search API key is required.
- **Standard n8n building blocks** — trigger, AI Agent node, and MCP Client Tool nodes; no custom code
  needed inside n8n itself.
- **No exposed attack surface** — every MCP/service endpoint is internal-only (Docker network isolation,
  no published host ports); secrets never touch git (`docker/.env` and the generated SearXNG secret are
  gitignored — `docker/.env.example` documents what's needed instead).
- **Pull instead of build, if you want** — `mcp-obsidian` and `mcp-searxng` (the two images this project
  actually builds) are published to GHCR on every change; `docker compose pull` skips building them from
  source. Both read their runtime config (port, vault name/mount) from plain environment variables — see
  [Reconfiguring things later](docs/SETUP.md#reconfiguring-things-later).

## 🛠️ Components

| Component | Project | Role |
|---|---|---|
| Vault mirror | [`vrtmrz/obsidian-livesync`](https://github.com/vrtmrz/obsidian-livesync) (`src/apps/cli`) | Headless daemon that keeps a plain-Markdown mirror of the vault in sync with the same MinIO/S3 (or CouchDB) remote used by the Self-hosted LiveSync plugin |
| Object storage | [MinIO](https://min.io/) | S3-compatible remote for Self-hosted LiveSync (assumed already running) |
| Orchestration | [n8n](https://n8n.io/) | Local File Trigger + AI Agent workflow (assumed already running) |
| Obsidian tools | [`StevenStavrakis/obsidian-mcp`](https://github.com/StevenStavrakis/obsidian-mcp) | MCP server for reading/writing/tagging notes directly on disk |
| Web research | [`SecretiveShell/MCP-searxng`](https://github.com/SecretiveShell/MCP-searxng) + [SearXNG](https://github.com/searxng/searxng) | MCP server exposing web search backed by a self-hosted meta search engine |
| stdio→HTTP bridge | [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) | Exposes the (stdio) MCP servers above as SSE endpoints n8n can call |

## 📊 Project status

Fully validated end-to-end on a real deployment — every piece of the pipeline above, including a real
ring recording — with no known open issues. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#open-questions--spikes)
for the detailed validation history if you want the evidence behind that claim.

## 📁 Project structure

```
pebble-index-research-agent/
├── docker/              # Compose stack: mcp-obsidian & mcp-searxng images, searxng config, .env.example
│   ├── mcp-obsidian/    # Dockerfile for the Obsidian MCP server
│   ├── mcp-searxng/     # Dockerfile for the SearXNG MCP server
│   └── searxng/         # SearXNG settings (settings.yml.example → settings.yml, gitignored)
├── n8n/workflows/       # Exported n8n workflow JSON (Local File Trigger + AI Agent)
├── docs/                # Setup guide, architecture rationale, troubleshooting log — see below
├── CLAUDE.md            # Deep implementation notes for this specific reference deployment
├── CONTRIBUTING.md      # How to propose changes
└── LICENSE              # AGPL v3
```

## 📚 Documentation

| Doc | What's in it |
|---|---|
| [`docs/SETUP.md`](docs/SETUP.md) | Step-by-step deployment guide (Phase 0-5), plus [Reconfiguring things later](docs/SETUP.md#reconfiguring-things-later) for changes after your first deploy (rotating credentials, switching models, moving paths, updating the repo, etc.) |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | The *why* behind every design decision, and the full validation history for each component |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Real errors hit while building this, with exact messages and fixes — check here first if something breaks |

## 🧰 Tech stack

<table>
<tr>
<td><strong>Orchestration</strong></td>
<td>
<img src="https://img.shields.io/badge/n8n-EA4B71?logo=n8n&logoColor=white" alt="n8n">
<img src="https://img.shields.io/badge/AI%20Agent-EA4B71" alt="AI Agent node">
<img src="https://img.shields.io/badge/MCP%20Client%20Tool-EA4B71" alt="MCP Client Tool node">
</td>
</tr>
<tr>
<td><strong>Vault sync</strong></td>
<td>
<img src="https://img.shields.io/badge/Self--hosted%20LiveSync-8A2BE2" alt="Self-hosted LiveSync">
<img src="https://img.shields.io/badge/MinIO-C72E49?logo=minio&logoColor=white" alt="MinIO">
</td>
</tr>
<tr>
<td><strong>Web research</strong></td>
<td>
<img src="https://img.shields.io/badge/SearXNG-3050FF" alt="SearXNG">
</td>
</tr>
<tr>
<td><strong>MCP tooling</strong></td>
<td>
<img src="https://img.shields.io/badge/obsidian--mcp-483699?logo=obsidian&logoColor=white" alt="obsidian-mcp">
<img src="https://img.shields.io/badge/MCP--searxng-3050FF" alt="MCP-searxng">
<img src="https://img.shields.io/badge/mcp--proxy-000000" alt="mcp-proxy">
</td>
</tr>
<tr>
<td><strong>LLM</strong></td>
<td>
<img src="https://img.shields.io/badge/OpenRouter-6467F2" alt="OpenRouter">
</td>
</tr>
<tr>
<td><strong>Deployment</strong></td>
<td>
<img src="https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white" alt="Docker">
<img src="https://img.shields.io/badge/GHCR-2496ED?logo=docker&logoColor=white" alt="GHCR">
</td>
</tr>
</table>

## ✅ Prerequisites

- A Core Devices Pebble Index 01 ring + the [Pebble mobile app](https://github.com/coredevices/mobileapp)
- An Obsidian vault using the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin,
  synced through your own MinIO (or other S3-compatible / CouchDB) instance
- A headless Linux server with Docker Engine + the Compose plugin (no Docker Desktop)
- An existing n8n instance (self-hosted) with access to that server
- An [OpenRouter](https://openrouter.ai/) API key — one key, free choice of underlying model

## 🤝 Contributing

Issues and PRs that improve accuracy, add support for other note-taking/sync backends, or simplify a
step are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for what to check before opening one (test
against a real instance where possible, keep `docs/` in sync, keep the default path fully
self-hostable).

## 📄 License

[GNU AGPLv3](LICENSE) — chosen specifically because this is self-hosted software: AGPL's network-use
clause means anyone who runs a modified version of this project as a service for others must also make
their modified source available, closing the "SaaS loophole" that plain GPL leaves open.

---

<p align="center">
  <a href="https://github.com/Delta-43/pebble-index-research-agent/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=Delta-43/pebble-index-research-agent" alt="Contributors" />
  </a>
</p>

<p align="center"><sub>Licensed under <a href="LICENSE">GNU AGPLv3</a>.</sub></p>
