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

_Pending validation — see `docs/ARCHITECTURE.md`._

## Phase 2 — MCP servers

_Pending validation — see `docs/ARCHITECTURE.md`._

## Phase 3 — n8n workflow

_Pending — workflow JSON will be exported to `n8n/workflows/` once built._

## Phase 4 — End-to-end test

_Pending._
