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

## Phase 1 — Vault mirror (`livesync-cli`)

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

_Pending validation — see `docs/ARCHITECTURE.md`._

## Phase 3 — n8n workflow

_Pending — workflow JSON will be exported to `n8n/workflows/` once built._

## Phase 4 — End-to-end test

_Pending._
