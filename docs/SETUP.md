# Setup guide

> This guide is being filled in phase-by-phase as each part of the stack is validated on real hardware.
> Checked items are confirmed working; unchecked items are planned/in progress.

## Prerequisites checklist

- [ ] Core Devices Pebble Index 01 ring, paired with the [Pebble mobile app](https://github.com/coredevices/mobileapp)
- [ ] Obsidian vault with the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin
      installed and syncing through your own MinIO (S3-compatible) bucket
- [ ] A headless Ubuntu server reachable via SSH, with Docker Engine + Compose plugin installed
      (see [Phase 0](#phase-0--docker-engine-on-a-headless-server))
- [ ] An existing n8n instance reachable from that server
- [ ] An [OpenRouter](https://openrouter.ai/) API key (gives free choice of underlying model with a
      single key — see Phase 3)

## Phase 0 — Docker Engine on a headless server

No Docker Desktop is required. On Ubuntu:

```bash
# remove old/conflicting packages
sudo apt-get remove docker docker-engine docker.io containerd runc

# prerequisites + Docker's official repo
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# install engine + compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# enable + run as non-root
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker

# sanity check
docker run --rm hello-world
```

## Phase 0.5 — Project directory, shared network, and secrets (`server-base-setup`)

**Validated** (`server-base-setup`, 2026-08-25) against `home_server`. Docker Engine 29.7.2 +
Compose plugin v5.5.0 confirmed already installed (matches Phase 0). Steps:

```bash
# 1. Clone this repo onto the server as the deployment checkout (re-`git pull` here on future updates)
mkdir -p /data/projects/pebble-index-research-agent
git clone https://github.com/Delta-43/pebble-index-research-agent.git \
  /data/projects/pebble-index-research-agent/repo

# 2. Create the project's own internal network (isolates searxng — see below)
docker network create pebble-agent-internal

# 3. Populate the real .env (gitignored, lives only on the server) from docker/.env.example
cp /data/projects/pebble-index-research-agent/repo/docker/.env.example \
   /data/projects/pebble-index-research-agent/repo/docker/.env
chmod 600 /data/projects/pebble-index-research-agent/repo/docker/.env
# ...then fill in the real MinIO endpoint/bucket/accessKey/secretKey (available in the already-
# bootstrapped livesync-settings.json from Phase 1 — see docs/ARCHITECTURE.md) and SearXNG config.
# LLM_API_KEY is intentionally left blank here: it's configured directly as an n8n credential
# (n8n-workflow-agent), no container in this compose stack needs it. LIVESYNC_PASSPHRASE is also left
# blank: the vault's E2EE passphrase is never stored in plaintext (`encryptedPassphrase` stays
# encrypted at rest), and vault-mirror-service reuses the already-bootstrapped settings.json rather
# than re-deriving credentials from an env var.
```

**Networking decision:** `docker-compose.yml` does **not** create one flat network for everything.
Instead:
- `n8n_n8n_internal` — n8n's own *existing* Docker network, declared `external: true` (this project
  doesn't own n8n's compose stack). `mcp-obsidian` and `mcp-searxng` join it so n8n's MCP Client Tool
  node can reach their SSE endpoints — this exact reachability path was already validated end-to-end in
  `spike-mcp-bridge` from the real, running `n8n` container.
- `pebble-agent-internal` — a new network dedicated to this project. `searxng` only joins this one, so
  it stays reachable exclusively by `mcp-searxng` (not by n8n or the host directly), matching the
  original "network-isolated" design goal for `searxng-service`. `mcp-searxng` bridges both networks.
- `livesync-cli` needs no explicit network — it only needs volume access and outbound HTTPS egress to
  MinIO, both of which work on Docker's default bridge.

Remaining for later todos: `vault-mirror-service` still needs to automate the one-time
`init-settings`/`setup`/`unlock-remote` bootstrap (currently manual, see Phase 1) — the bind-mount
wiring itself is done. `searxng-service` is resolved: **not** reusing `n8n-searxng-1` (see Phase 2).

## Phase 1 — Vault mirror bootstrap (`livesync-cli`)

**Validated** against a real MinIO/S3 remote using Journal Sync (see `docs/ARCHITECTURE.md` and
`docs/TROUBLESHOOTING.md` for full details/gotchas). Summary of the working bootstrap sequence:

```bash
# 1. Build the CLI image (once)
git clone --depth 1 https://github.com/vrtmrz/obsidian-livesync.git
cd obsidian-livesync
docker build -f src/apps/cli/Dockerfile -t livesync-cli .

# 2. Create a fresh settings file
docker run --rm -v <data-dir>:/data livesync-cli init-settings /data/livesync-settings.json

# 3. Apply the Setup URI exported from Obsidian (Settings -> Sync Settings -> copy/QR "Setup URI")
printf '%s\n' "$SETUP_URI_PASSCODE" | \
  docker run -i --rm -v <data-dir>:/data -v <vault-dir>:/vault livesync-cli \
    --settings /data/livesync-settings.json setup "$SETUP_URI"

# 4. One-time device acceptance (only needed the first time a new device connects)
docker run --rm -v <data-dir>:/data -v <vault-dir>:/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault unlock-remote <remote-id>

# 5. Pull once and materialise real files, then verify
docker run --rm -v <data-dir>:/data -v <vault-dir>:/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault sync
docker run --rm -v <data-dir>:/data -v <vault-dir>:/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault mirror

# 6. Run continuously (this is what the docker-compose `livesync-cli` service does)
docker run -d --rm -v <data-dir>:/data -v <vault-dir>:/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault daemon
```

**VALIDATED** (`vault-mirror-service`): the standing `livesync-cli` compose service now bind-mounts
`VAULT_MIRROR_DATA_PATH`/`VAULT_MIRROR_PATH` (host directories set in `docker/.env`) instead of scratch
named volumes, so `settings.json` and the mirrored vault persist at a stable, known host path other
services (`mcp-obsidian`, later n8n's Local File Trigger) can share directly. Steps 2-4 above (init,
setup, unlock-remote) are still a manual one-time bootstrap, not run automatically on container start —
that automation, and the root-owned-files permission question, remain open for a future pass; see
`docs/TROUBLESHOOTING.md`.

## Phase 2 — MCP servers & SearXNG

**Validated** (`spike-mcp-bridge`) that `sparfenyuk/mcp-proxy` can bridge both stdio MCP servers to SSE
endpoints n8n's MCP Client Tool node can call — see `docs/ARCHITECTURE.md` and
`docs/TROUBLESHOOTING.md` for full findings/gotchas (in particular: **do not** `npx -y mcp-proxy`, that
resolves to an unrelated npm package).

**Validated** (`searxng-service`, 2026-08-25) on the real server. Turns out the already-running
`n8n-searxng-1` is an internal piece of n8n's own `instance-ai` sandbox feature (chained to a privileged
Docker-in-Docker sandbox runner), not a general-purpose instance — it sits stopped whenever that sandbox
is idle, independent of n8n's own uptime. Standing up this project's own dedicated `searxng` (already
sketched in `docker-compose.yml`) instead. One-time setup before first deploy:

```bash
cp docker/searxng/settings.yml.example docker/searxng/settings.yml
sed -i "s/ultrasecretkey/$(openssl rand -hex 32)/" docker/searxng/settings.yml
```

`settings.yml` is gitignored (holds a real secret) — `settings.yml.example` is the tracked template.
**Do skip this step and current SearXNG (2026.8.22) will crash-loop at startup**: it hard-refuses to run
at all with the literal `ultrasecretkey` placeholder still in place (`server.secret_key is not
changed... [ERROR] Unexpected exit from worker-1`) — this is a startup precondition now, not just a
CSRF-hardening suggestion. Confirmed working after generating a real secret: `docker compose up -d
searxng` starts cleanly and `/search?format=json` returns real results.

```bash
# --- obsidian-mcp bridge ---
# Vault dir must already contain an (empty is fine) .obsidian/ directory — Journal Sync doesn't
# replicate it, so create it once:
docker run --rm -v <vault-dir>:/vault alpine mkdir -p /vault/.obsidian

# Base image needs both Node (for obsidian-mcp) and Python (for the real mcp-proxy):
docker run -d --name mcp-obsidian -p 8801:8801 -v <vault-dir>:/vault node:22-slim sh -c \
  "apt-get update -qq && apt-get install -qq -y python3 python3-pip > /dev/null && \
   pip install --quiet --break-system-packages 'mcp<2' mcp-proxy && \
   exec mcp-proxy --port=8801 --host=0.0.0.0 --pass-environment -- \
     npx -y obsidian-mcp@2 serve --vault notes=/vault"

# --- mcp-searxng bridge ---
# Install mcp-searxng from source (PyPI 0.1.0 is stale/incompatible with current SearXNG's JSON schema):
docker run -d --name mcp-searxng -p 8802:8802 -e SEARXNG_URL=http://searxng:8080 python:3.12-slim sh -c \
  "apt-get update -qq && apt-get install -qq -y git > /dev/null && \
   pip install --quiet 'mcp<2' mcp-proxy 'git+https://github.com/SecretiveShell/MCP-searxng.git' && \
   exec mcp-proxy --port=8802 --host=0.0.0.0 --pass-environment -- mcp-searxng"
```

Both expose an SSE endpoint at `http://<container-name>:<port>/sse` on whatever Docker network they
share with n8n and (for `mcp-searxng`) SearXNG. Point n8n's **MCP Client Tool** node at that URL.

Remaining for `mcp-obsidian-service` / `mcp-searxng-service`: bake the above `apt-get`/`pip install`
steps into real committed Dockerfiles (see `docker/mcp-obsidian/Dockerfile` and
`docker/mcp-searxng/Dockerfile`) instead of running them ad hoc at container start every time, and
decide whether to reuse the already-running `n8n-searxng-1` SearXNG instance (already has JSON format
enabled) or stand up a fully separate one (`searxng-service`).

## Phase 3 — n8n workflow

**Validated** (`n8n-workflow-trigger`, `n8n-workflow-agent`, 2026-08-25): built, imported into the real
`n8n` instance, and round-tripped via `import:workflow`/`export:workflow` with no dropped fields. The
workflow JSON is committed at `n8n/workflows/pebble-index-research-agent.json`. Not yet activated or
tested against a real note — that's Phase 4, and needs one manual step first (below) that only you can
safely do, since it needs a real API key.

**Step 1 — mount the vault mirror into n8n itself.** The Local File Trigger node runs inside n8n's own
container, so it needs read access to the same host path `livesync-cli` writes to. This means editing
n8n's own `compose.yml` (wherever your n8n stack lives, not this repo) to add a bind mount:
```yaml
    volumes:
      - /data/vault-mirror/vault:/vault-mirror:ro   # adjust to your VAULT_MIRROR_PATH
```
then `docker compose up -d n8n` to apply it. This briefly restarts n8n (confirmed: a few seconds of
downtime, `healthz` recovers on its own once the container comes back up).

**Step 2 — import the workflow:**
```bash
docker cp n8n/workflows/pebble-index-research-agent.json n8n:/tmp/wf.json
docker exec n8n n8n import:workflow --input=/tmp/wf.json
```

**Step 3 — add an OpenRouter credential.** The workflow ships with its `OpenRouter Chat Model` node's
credential intentionally unset (see `docs/ARCHITECTURE.md`) — open the workflow in the n8n editor,
click that node, and attach (or create) an OpenRouter credential (just an API key from
[openrouter.ai](https://openrouter.ai/settings/keys)). To choose the model, edit that same node's
`Model` field — it's a plain string, e.g. `openai/gpt-5-mini`, `anthropic/claude-sonnet-4.6`,
`google/gemini-3.1-pro-preview`, or any other slug from [openrouter.ai/models](https://openrouter.ai/models)
— no node graph changes needed to switch models later, just edit that field.

**Step 4 — activate the workflow** in the n8n editor once the credential is attached.

## Phase 4 — End-to-end test

_Pending — needs Phase 3's manual steps done first. Once activated, drop a `.md` file into `Index
Inbox/` in the vault (or record a real note on the ring) and check the `Research/` folder for the
resulting note, and n8n's Executions list for the run._
