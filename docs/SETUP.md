# Setup guide

A step-by-step deployment guide, validated end-to-end on a real headless Ubuntu server. For the *why*
behind each decision, see [`ARCHITECTURE.md`](ARCHITECTURE.md); for exact error messages and fixes if
something goes wrong, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — several steps below hit real,
non-obvious failure modes during development, called out inline with a link to the full details.

Commands below use placeholder paths/names in `<angle brackets>` — replace them with your own. Where
this project's own real deployment used a specific value (e.g. a folder name, a network name), that's
called out explicitly so you know it's an example, not a requirement.

## Prerequisites

- A Core Devices Pebble Index 01 ring, paired with the [Pebble mobile app](https://github.com/coredevices/mobileapp)
- An Obsidian vault with the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin
  installed and syncing through your own MinIO (or other S3-compatible) bucket
- A headless Ubuntu server reachable via SSH, with Docker Engine + Compose plugin (see Phase 0 if not)
- An existing n8n instance (self-hosted), reachable from that server
- An [OpenRouter](https://openrouter.ai/) API key (one key, free choice of underlying model — see Phase 4)

## Phase 0 — Docker Engine on the server

Skip if Docker is already installed. No Docker Desktop needed — plain Docker Engine + Compose plugin:

```bash
sudo apt-get remove docker docker-engine docker.io containerd runc

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker

docker run --rm hello-world   # sanity check
```

## Phase 1 — Clone the repo and configure secrets

```bash
# 1. Clone this repo wherever you want it deployed from
git clone https://github.com/Delta-43/pebble-index-research-agent.git
cd pebble-index-research-agent

# 2. Create this project's own internal network (isolates searxng — see ARCHITECTURE.md)
docker network create pebble-agent-internal

# 3. Copy and fill in the real .env — never commit this file
cp docker/.env.example docker/.env
chmod 600 docker/.env
```

Now edit `docker/.env`:

- **`LIVESYNC_S3_*`** — your MinIO/S3 endpoint, bucket, access key, secret key. Get these from the
  Self-hosted LiveSync plugin's own settings (Obsidian → Settings → Self-hosted LiveSync → Sync
  Settings), or from wherever you originally configured your MinIO/S3 remote. `LIVESYNC_PASSPHRASE` can
  stay blank — the vault's E2EE passphrase isn't needed here (see Phase 2).
- **`LLM_API_KEY`** — leave blank. The OpenRouter key goes into n8n directly as a credential (Phase 4),
  not into this compose stack.
- **`SEARXNG_URL`** — leave as the default (`http://searxng:8080`) unless you change the `searxng`
  service name in `docker-compose.yml`.
- **`VAULT_MIRROR_DATA_PATH`** / **`VAULT_MIRROR_PATH`** — pick two absolute host directories (e.g.
  `/data/vault-mirror/data` and `/data/vault-mirror/vault`). They'll be created if they don't exist.
- **`N8N_NETWORK_NAME`** — the Docker network your *existing* n8n container is already on. Find it with:
  ```bash
  docker inspect <your-n8n-container-name> --format '{{json .NetworkSettings.Networks}}'
  ```
  (or `docker network ls` and match by inspecting candidates). Every n8n install names this differently
  depending on its own compose project name — this project's own deployment happens to use
  `n8n_n8n_internal`, but don't assume that's yours.

Then generate the SearXNG secret (a checked-in placeholder won't work — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#searxng-deployment-searxng-service) for why):

```bash
cp docker/searxng/settings.yml.example docker/searxng/settings.yml
sed -i "s/ultrasecretkey/$(openssl rand -hex 32)/" docker/searxng/settings.yml
```

## Phase 2 — Bootstrap the vault mirror

`livesync-cli` needs a one-time, interactive bootstrap before it can run unattended — it needs your
vault's E2EE passphrase once, which is why this can't be automated into `docker-compose.yml`.

```bash
# Build the CLI image (also happens automatically on first `docker compose up`, but building it once
# here lets you run the one-off bootstrap commands below directly)
docker build -f src/apps/cli/Dockerfile -t livesync-cli https://github.com/vrtmrz/obsidian-livesync.git

DATA_DIR=<same as VAULT_MIRROR_DATA_PATH in docker/.env>
VAULT_DIR=<same as VAULT_MIRROR_PATH in docker/.env>
mkdir -p "$DATA_DIR" "$VAULT_DIR"

# 1. Create a fresh settings file
docker run --rm -v "$DATA_DIR":/data livesync-cli init-settings /data/livesync-settings.json

# 2. Apply the Setup URI exported from Obsidian (Settings → Self-hosted LiveSync → Sync Settings →
# copy/QR "Setup URI"). Needs -i (interactive) since it prompts for the URI's passphrase on stdin.
printf '%s\n' "$SETUP_URI_PASSCODE" | \
  docker run -i --rm -v "$DATA_DIR":/data -v "$VAULT_DIR":/vault livesync-cli \
    --settings /data/livesync-settings.json setup "$SETUP_URI"

# 3. One-time device acceptance — only needed the first time this specific device (this CLI install)
# connects. <remote-id> is the key under `remoteConfigurations` in the settings.json step 2 wrote.
docker run --rm -v "$DATA_DIR":/data -v "$VAULT_DIR":/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault unlock-remote <remote-id>

# 4. Pull once and materialise real files
docker run --rm -v "$DATA_DIR":/data -v "$VAULT_DIR":/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault sync
docker run --rm -v "$DATA_DIR":/data -v "$VAULT_DIR":/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault mirror

# 5. Journal Sync doesn't replicate the .obsidian/ config folder, but obsidian-mcp (Phase 3) refuses a
# vault without one — create an empty one once:
docker run --rm -v "$VAULT_DIR":/vault alpine mkdir -p /vault/.obsidian
```

If step 2 instead fails with `The remote database is locked and this device is not yet accepted`, that
*is* step 3 — run it and retry. See
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#livesync-cli--vault-mirror-spike-livesync-s3) if anything else
goes wrong here.

## Phase 3 — Deploy the stack

```bash
cd docker
docker compose up -d --build
```

This starts `livesync-cli` (in continuous `daemon` mode — picks up from the one-shot bootstrap above),
`searxng`, `mcp-obsidian`, and `mcp-searxng`. Verify each:

```bash
# searxng: real search results, JSON format. No host port is published (internal-only by design), so
# run the check from a throwaway container on the same network:
docker run --rm --network pebble-agent-internal curlimages/curl:latest \
  -s 'http://searxng:8080/search?q=test&format=json'

# mcp-obsidian / mcp-searxng: SSE handshake, reachable from n8n specifically
docker exec <your-n8n-container-name> wget -qO- --timeout=3 http://mcp-obsidian:8801/sse
docker exec <your-n8n-container-name> wget -qO- --timeout=3 http://mcp-searxng:8802/sse
```

Each should return `event: endpoint` / `data: /messages/?session_id=...` and then hang (that's correct —
it's a long-lived SSE stream; `Ctrl+C` or let the command time out).

## Phase 4 — Wire up n8n

**Step 1 — mount the vault mirror into n8n itself, and clear two default security restrictions.** The
Local File Trigger node runs inside n8n's own container, so it needs read access to the same host path
`livesync-cli` writes to. Edit n8n's own `compose.yml` (wherever your n8n stack lives — **not** this
repo) to add a bind mount and two environment variables. Recent n8n versions exclude
filesystem-touching nodes by default (sensible for an internet-facing instance), and this workflow
needs two of them re-enabled:

```yaml
    environment:
      # ...your existing vars...
      # Re-enable just the Local File Trigger node; leave the more dangerous executeCommand blocked.
      NODES_EXCLUDE: '["n8n-nodes-base.executeCommand"]'
      # Default only allows file-system nodes to touch ~/.n8n-files. Add the vault mirror mount path.
      N8N_RESTRICT_FILE_ACCESS_TO: '/vault-mirror;~/.n8n-files'
    volumes:
      - <your VAULT_MIRROR_PATH>:/vault-mirror:ro
```

Mount it at exactly `/vault-mirror` — that's the path baked into the workflow JSON you'll import next.
Then apply it:

```bash
docker compose up -d <your-n8n-service-name>   # or however you normally restart your n8n deployment
```

This briefly restarts n8n (a few seconds of downtime; `healthz` recovers on its own). **Both env vars
are required — missing either one makes the trigger fail silently**: the workflow shows
"Published"/"Active" in the UI with no error, but the trigger either never registers or throws `Access
to the file is not allowed.` on every run. See
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#n8n-workflow-build-n8n-workflow-trigger-n8n-workflow-agent)
for exactly what each failure looks like if you hit it anyway.

**Step 2 — import the workflow:**

```bash
docker cp n8n/workflows/pebble-index-research-agent.json <your-n8n-container-name>:/tmp/wf.json
docker exec <your-n8n-container-name> n8n import:workflow --input=/tmp/wf.json
```

⚠️ If you ever re-run this later (e.g. after `git pull`-ing an updated version of this workflow), it
will silently overwrite the credential/model you set in Step 4 below and deactivate the workflow — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#n8n-workflow-build-n8n-workflow-trigger-n8n-workflow-agent).

**Step 3 — check the ring-notes folder name matches your vault.** This project's own vault saves
transcribed notes to a folder called `Index Inbox/` — yours may be named differently (check your vault,
or the Pebble app's settings). If so, open the imported workflow in the n8n editor, click the **Watch
Index Inbox** node, and change its `Folder to Watch` field from `/vault-mirror/Index Inbox` to
`/vault-mirror/<your folder name>`. Nothing else needs to change — the rest of the workflow reads the
folder name through automatically.

**Step 4 — add an OpenRouter credential.** The `OpenRouter Chat Model` node's credential ships
intentionally unset. Click that node in the editor and attach (or create) an OpenRouter credential —
just an API key from [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys). To choose a
model, edit that same node's **Model** field — it's a plain string, e.g. `openai/gpt-5-mini`,
`anthropic/claude-sonnet-4.6`, `google/gemini-3.1-pro-preview`, or any other slug from
[openrouter.ai/models](https://openrouter.ai/models) (including free-tier models) — no node graph
changes needed to switch models later, just edit that field.

**Step 5 — activate the workflow**, then restart n8n once more:

```bash
docker compose up -d <your-n8n-service-name>   # or however you normally restart your n8n deployment
```

n8n only builds its list of which triggers to actually start listening for **once, at process boot** —
activating a workflow while n8n is already running updates the database immediately, but the running
process won't actually start watching until it restarts.

## Phase 5 — Test it

Drop a `.md` file into your ring-notes folder (or record a real note on the ring). The folder is
root-owned (the official `livesync-cli` image doesn't drop privileges — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#livesync-cli--vault-mirror-spike-livesync-s3)), so write it
via a throwaway container rather than a plain shell redirect, which will hit `Permission denied` for
most users:

```bash
printf -- '---\ntags: [index, index_note]\n---\n\nWhat is the best way to brew pour-over coffee at home?\n' | \
  docker run --rm -i -v <your VAULT_MIRROR_PATH>:/vault alpine sh -c \
    "cat > '/vault/<your folder name>/test-note.md'"
```

Within a few seconds, check:

- **n8n's Executions list** — a new run of "Pebble Index → Research Note" should appear.
- **Your vault's `Research/` folder** — a new, titled, tagged note with a `source` link back to the
  original.
- **Your phone/desktop Obsidian** — the new note should sync down automatically via
  Self-hosted LiveSync, next time it connects. This works even if no Obsidian instance was open on any
  device while the note was created — see
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#livesync-cli--vault-mirror-spike-livesync-s3) for how to
  verify sync directly against your MinIO bucket if you want independent confirmation before waiting on
  your phone.
