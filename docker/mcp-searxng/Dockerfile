# Bridges the stdio `mcp-searxng` server to an SSE endpoint using the real `sparfenyuk/mcp-proxy` —
# validated in spike-mcp-bridge. See docs/ARCHITECTURE.md and docs/TROUBLESHOOTING.md for why
# mcp-searxng is installed from git source rather than PyPI, and why `mcp` must be pinned below 2.0.
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# PyPI's mcp-searxng==0.1.0 requires a `number_of_results` field that current SearXNG no longer
# returns from /search?format=json; main branch on GitHub already dropped that requirement.
# Exact versions and a fixed upstream commit, bumped by Renovate PRs (see renovate.json).
# renovate: datasource=pypi depName=mcp
ARG MCP_VERSION=1.30.0
# renovate: datasource=pypi depName=mcp-proxy
ARG MCP_PROXY_VERSION=0.12.0
# renovate: datasource=git-refs depName=https://github.com/SecretiveShell/MCP-searxng currentValue=master
ARG MCP_SEARXNG_COMMIT=7aba5ed80656818132ebaff35bde50c9c6d757be
RUN pip install --no-cache-dir "mcp==${MCP_VERSION}" "mcp-proxy==${MCP_PROXY_VERSION}" \
    "git+https://github.com/SecretiveShell/MCP-searxng.git@${MCP_SEARXNG_COMMIT}"

# Configurable at `docker run`/compose time. SEARXNG_URL is read directly by mcp-searxng itself
# (forwarded through by --pass-environment) — set it to point at any SearXNG instance, not just the
# one in this project's own docker-compose.yml.
ENV MCP_PORT=8802

ENTRYPOINT ["/bin/sh", "-c", "exec mcp-proxy --host 0.0.0.0 --port \"$MCP_PORT\" --pass-environment -- mcp-searxng"]
