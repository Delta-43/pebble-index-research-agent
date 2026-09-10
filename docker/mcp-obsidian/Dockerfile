# Bridges the stdio `obsidian-mcp` server (Node) to an SSE endpoint using the real
# `sparfenyuk/mcp-proxy` (Python) — validated in spike-mcp-bridge. See docs/ARCHITECTURE.md and
# docs/TROUBLESHOOTING.md for why this combines two runtimes and why `mcp` must be pinned below 2.0.
FROM node:22-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip inotify-tools \
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

# `obsidian-mcp@2` hardcodes 0600 (owner-only) for every file it writes, with no config override —
# fine as long as only this container (root) ever reads its own writes, but it silently breaks any
# *other* process (e.g. n8n's own non-root user, reading a note back for a different trigger) that
# needs to read a note obsidian-mcp created. See docs/TROUBLESHOOTING.md. Since this container already
# runs as root — the same owner as obsidian-mcp's writes — watch the vault and loosen every new file to
# 644 the instant it lands, rather than patching the upstream library.
ENTRYPOINT ["/bin/sh", "-c", "(inotifywait -m -r -e create,moved_to,close_write --format '%w%f' \"$VAULT_MOUNT\" 2>/dev/null | while IFS= read -r f; do [ -f \"$f\" ] && chmod 644 \"$f\" 2>/dev/null; done &) ; exec mcp-proxy --host 0.0.0.0 --port \"$MCP_PORT\" --pass-environment -- npx -y obsidian-mcp@2 serve --vault \"$VAULT_NAME=$VAULT_MOUNT\""]
