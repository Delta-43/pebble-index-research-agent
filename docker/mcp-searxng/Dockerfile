# Bridges the stdio `mcp-searxng` server to an SSE endpoint using the real `sparfenyuk/mcp-proxy` —
# validated in spike-mcp-bridge. See docs/ARCHITECTURE.md and docs/TROUBLESHOOTING.md for why
# mcp-searxng is installed from git source rather than PyPI, and why `mcp` must be pinned below 2.0.
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# PyPI's mcp-searxng==0.1.0 requires a `number_of_results` field that current SearXNG no longer
# returns from /search?format=json; main branch on GitHub already dropped that requirement.
RUN pip install --no-cache-dir "mcp<2" mcp-proxy \
    "git+https://github.com/SecretiveShell/MCP-searxng.git"

ENTRYPOINT ["mcp-proxy", "--host", "0.0.0.0", "--pass-environment"]
CMD ["--port", "8802", "--", "mcp-searxng"]
