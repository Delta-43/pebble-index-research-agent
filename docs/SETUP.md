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
- [ ] A cloud LLM API key (OpenAI, Anthropic, or Gemini)

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
`init-settings`/`setup`/`unlock-remote` bootstrap (currently manual, see Phase 1); `searxng-service`
still needs to decide reuse-vs-isolate against the already-running `n8n-searxng-1` (see
`docs/ARCHITECTURE.md`).



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

Remaining for `vault-mirror-service`: wire the above into the standing compose service (persist
`settings.json` in the `livesync_db` volume, run steps 2-4 as a one-time bootstrap rather than on every
container start), and resolve the root-owned-files permission question noted in
`docs/TROUBLESHOOTING.md`.

## Phase 2 — MCP servers

**Validated** (`spike-mcp-bridge`) that `sparfenyuk/mcp-proxy` can bridge both stdio MCP servers to SSE
endpoints n8n's MCP Client Tool node can call — see `docs/ARCHITECTURE.md` and
`docs/TROUBLESHOOTING.md` for full findings/gotchas (in particular: **do not** `npx -y mcp-proxy`, that
resolves to an unrelated npm package).

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

_Pending — workflow JSON will be exported to `n8n/workflows/` once built._

## Phase 4 — End-to-end test

_Pending._
