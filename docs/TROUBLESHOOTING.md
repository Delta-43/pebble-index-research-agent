# Troubleshooting

Real issues (and their fixes) hit while building and running this stack.

## `livesync-cli` / vault mirror (`spike-livesync-s3`)

**Building:** the official Dockerfile builds cleanly from the repo root:
`docker build -f src/apps/cli/Dockerfile -t livesync-cli .` (multi-stage, ~1-2 min, compiles native
`leveldown` bindings). No local Node/npm install needed on the host.

**`init-settings` writes nowhere useful if run without a path.** The Docker entrypoint only prepends
the database-path (`/data`) for most commands — `init-settings` is special-cased to run with no leading
path, so `docker run -v host:/data livesync-cli init-settings` (no args) writes `/app/data.json`
*inside the container*, which is lost on exit. Always give it an explicit path under the mounted
volume: `livesync-cli init-settings /data/livesync-settings.json`.

**Applying the plugin's Setup URI is the easiest way to configure a remote.** Rather than typing the
MinIO endpoint/bucket/access key/secret/passphrase by hand, export "Setup URI" from the Obsidian
Self-hosted LiveSync plugin (Settings → Sync Settings) and run:
```bash
printf '%s\n' "$SETUP_URI_PASSCODE" | \
  docker run -i --rm -v <data>:/data -v <vault>:/vault livesync-cli \
    --settings /data/livesync-settings.json setup "$SETUP_URI"
```
The passcode prompt (`Enter setup URI passphrase:`) is answered via stdin — needs `docker run -i`
(interactive) or it'll hang/fail. This correctly populated `remoteType: "MINIO"`, `endpoint`, `bucket`,
`accessKey`/`secretKey`, `bucketPrefix`, `chunkSplitterVersion`, etc. verbatim from the plugin's config.

**First sync from a new device fails with a lock error**, even with correct credentials:
```
[Error] The remote database is locked and this device is not yet accepted.
[Error] Please unlock the database from the Obsidian plugin and retry.
```
This is Journal Sync's device-handshake safety mechanism (a milestone doc tracks `locked` +
`accepted_nodes`). Fix — run once per new device:
```bash
docker run --rm -v <data>:/data -v <vault>:/vault livesync-cli \
  --settings /data/livesync-settings.json --vault /vault unlock-remote <remote-id>
```
(`<remote-id>` is the key under `remoteConfigurations` in `settings.json`, e.g. `remote-mt5sbt2a-u73qoz`.)
This only flips a coordination flag and registers the device's node ID as accepted — it does not touch
note content and is safe to run against a live, in-use vault.

**`sync` alone does not write files to disk.** One-shot `sync` pulls/pushes the encrypted replication
log but logs `Replication result received, but not processed automatically in CLI mode.` and leaves the
vault directory untouched. Follow it with `mirror` (materializes DB → local `.md` files) — or just use
`daemon` mode, which does an initial mirror scan (both directions) before it starts continuously
watching.

**The `.jsonl.gz` journal objects in the bucket are not real gzip** to an outside observer — they're
gzip-then-encrypted (E2EE), so `gunzip`/`mc cat | gunzip` on them fails with `not in gzip format`. This
is expected and confirms end-to-end encryption is actually in effect at rest; only `livesync-cli` (with
the right passphrase) can decrypt them.

**Files created by the official Docker image are owned by `root`** (no non-root user is dropped to in
the image), so a plain host user can't write directly into the mirrored vault directory — use a
throwaway container (e.g. `docker run --rm -v <vault>:/vault alpine ...`) or match UID/GID when other
services need write access to the same volume.

**MinIO in this deployment requires HTTPS** even for local/internal calls (certs mounted into the
container) — `mc alias set ... http://...` fails with *"Client sent an HTTP request to an HTTPS
server"*; use `https://` (`--insecure` if the cert isn't trusted by the calling client) instead.

## MCP stdio→SSE bridging (`spike-mcp-bridge`)

**`npx -y mcp-proxy` silently resolves to the wrong package.** There are two unrelated projects called
`mcp-proxy`: `sparfenyuk/mcp-proxy` (Python, PyPI, the one this project is built around — `--port`,
`--host`, `--pass-environment` style flags) and `punkpeye/mcp-proxy` (npm, TypeScript, `--server`,
`--sseEndpoint`, `--streamEndpoint` style flags). `npx -y mcp-proxy` installs the npm one. Confirmed via
`npm view mcp-proxy repository.url` → `git+https://github.com/punkpeye/mcp-proxy.git`. Always install
the real one with `pip`/`pipx`/`uv install mcp-proxy`, or run `ghcr.io/sparfenyuk/mcp-proxy`; never
`npx -y mcp-proxy`.

**`pip install mcp-proxy` (0.12.0) breaks with the newest `mcp` package.**
```
ImportError: cannot import name 'request_ctx' from 'mcp.server.lowlevel.server'
```
`mcp-proxy`'s own `pyproject.toml` only requires `mcp>=1.27.1` (which technically allows `mcp` 2.x), but
`mcp` 2.x renamed/removed internals `mcp-proxy` 0.12.0 depends on. Fix: pin it explicitly —
`pip install 'mcp<2' mcp-proxy` (resolves to `mcp==1.29.1`, confirmed working).

**Env vars don't reach the wrapped stdio server unless you say so.** `mcp-proxy` does not pass its own
environment through to the child process by default — `mcp-searxng`'s `search` calls failed with `All
connection attempts failed` even though `SEARXNG_URL` was correctly set on the container, because the
spawned `mcp-searxng` subprocess simply didn't see it. Fix: add `--pass-environment` (or `-e KEY VALUE`
per variable) to the `mcp-proxy` invocation.

**`pip install mcp-searxng` (PyPI `0.1.0`) is stale and fails every real search** once the env var issue
above is fixed:
```
1 validation error for Response
number_of_results
  Field required [type=missing, ...]
```
The published package's `Response` model requires `number_of_results`, a field this deployment's
SearXNG no longer includes in `/search?format=json` output (confirmed by curling the endpoint directly
and inspecting the JSON keys: `query`, `results`, `infoboxes`, `answers`, `corrections`, `suggestions`,
`unresponsive_engines` — no `number_of_results`). GitHub's `main` branch already removed that
requirement; PyPI hasn't caught up. Fix: install from source —
`pip install git+https://github.com/SecretiveShell/MCP-searxng.git`.

**`obsidian-mcp@2` refuses a vault directory without an `.obsidian/` folder.** The mirrored vault
produced by `livesync-cli` (Journal Sync only replicates content, not the `.obsidian` config folder)
won't have one. Create an empty one once: `docker run --rm -v <vault>:/vault alpine mkdir -p
/vault/.obsidian`. `vault-mirror-service` should do this as part of its bootstrap, not as a manual step.

**`obsidian_delete_note`'s permanent-delete param is `mode: "permanent"`, not a boolean `permanent`
flag** — confirmed by inspecting the tool's real JSON schema over the wire (`list_tools()`); also
requires `confirm_path` to exactly match the note's path.

**Validated end-to-end (real containers on `home_server`, real MCP protocol round-trips, not just an
SSE handshake check):**
- `obsidian-mcp` bridge: `node:22-slim` + `python3-pip` + `pip install 'mcp<2' mcp-proxy`, then
  `mcp-proxy --port 8801 --host 0.0.0.0 --pass-environment -- npx -y obsidian-mcp@2 serve --vault
  notes=/vault`. Confirmed `obsidian_list_vaults`, real `obsidian_read_note` content, and a
  create→delete round trip via a throwaway test note (cleaned up afterwards).
- `mcp-searxng` bridge: `python:3.12-slim` + `git` + `pip install 'mcp<2' mcp-proxy
  git+https://github.com/SecretiveShell/MCP-searxng.git`, then `mcp-proxy --port 8802 --host 0.0.0.0
  --pass-environment -- mcp-searxng` (`SEARXNG_URL=http://searxng:8080`, the existing `n8n-searxng-1`
  container's DNS alias on the shared `n8n_n8n_internal` network). Confirmed the `search` tool returns
  real, live web results.
- Both SSE endpoints (`http://<container>:<port>/sse`) were confirmed reachable by `wget`-ing them from
  inside the actual, already-running `n8n` container itself (not just a throwaway test client),
  validating the exact path n8n's MCP Client Tool node will use.
- `obsidian-mcp@2` logs a harmless `[LEGACY_MCP_PROTOCOL]` warning against `mcp-proxy` (2025-era
  handshake) — expected, not a bug; do not add `--legacy reject`.


