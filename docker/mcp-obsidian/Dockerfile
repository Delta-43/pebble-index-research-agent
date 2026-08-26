# Bridges the stdio `obsidian-mcp` server (Node) to an SSE endpoint using the real
# `sparfenyuk/mcp-proxy` (Python) — validated in spike-mcp-bridge. See docs/ARCHITECTURE.md and
# docs/TROUBLESHOOTING.md for why this combines two runtimes and why `mcp` must be pinned below 2.0.
FROM node:22-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# `mcp<2` is required: mcp-proxy 0.12.0 is incompatible with the `mcp` 2.x API despite its loose
# `mcp>=1.27.1` constraint (see docs/TROUBLESHOOTING.md).
RUN pip install --no-cache-dir --break-system-packages "mcp<2" mcp-proxy

# Configurable at `docker run`/compose time via env vars — no need to override the whole CMD to change
# just one thing. VAULT_MOUNT is the *container-internal* mount point; point your bind mount at it
# (default /vault matches this project's own docker-compose.yml).
ENV MCP_PORT=8801
ENV VAULT_NAME=notes
ENV VAULT_MOUNT=/vault

ENTRYPOINT ["/bin/sh", "-c", "exec mcp-proxy --host 0.0.0.0 --port \"$MCP_PORT\" --pass-environment -- npx -y obsidian-mcp@2 serve --vault \"$VAULT_NAME=$VAULT_MOUNT\""]
