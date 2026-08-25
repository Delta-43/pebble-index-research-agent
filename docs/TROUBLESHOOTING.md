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

## SearXNG deployment (`searxng-service`)

**Declaring a project network without `external: true` silently creates a differently-named,
duplicate network — even when a network of the intended name already exists.** `docker-compose.yml`
declared `pebble-agent-internal` as a plain `driver: bridge` network. `docs/SETUP.md` Phase 0.5 already
creates a real `pebble-agent-internal` network as a one-time manual step before first deploy — but
without `external: true`, Compose doesn't know that and instead creates its own
`<project-name>_pebble-agent-internal` (project name defaults to the directory the compose file lives
in, e.g. `docker` here → `docker_pebble-agent-internal`), and attaches `searxng` to *that* instead.
Confirmed on `home_server`: `docker compose up -d searxng` created `docker_pebble-agent-internal`
alongside the pre-existing (correct) `pebble-agent-internal`, silently diverging from the network every
other doc/comment in this repo references by name. Fix: mark it `external: true` in
`docker-compose.yml` so Compose reuses the network Phase 0.5 already created, rather than assuming
Compose will infer that from the name alone.

**Current SearXNG (2026.8.22) refuses to start at all with the default `secret_key` placeholder** —
this is new/stronger behavior than older "just rotate it before exposing publicly" guidance suggests.
Leaving `server.secret_key: "ultrasecretkey"` in a bind-mounted `settings.yml` (bind-mounting bypasses
the image's own entrypoint, which only auto-randomizes a *freshly generated* settings.yml, never one
supplied via a mount) causes an immediate, permanent crash loop:
```
ERROR:searx.webapp: server.secret_key is not changed. Please use something else instead of ultrasecretkey.
[ERROR] Unexpected exit from worker-1
```
This happens regardless of network exposure — confirmed it crash-loops even fully isolated on
`pebble-agent-internal` with no published port and no reachability from n8n or the host. Fix: generate
a real secret before first deploy — `docker/searxng/settings.yml.example` (tracked) has the placeholder
and the exact command; `docker/searxng/settings.yml` (gitignored, holds the real secret) is what's
actually mounted. After that, `docker compose up -d searxng` starts cleanly and `curl
'http://searxng:8080/search?q=...&format=json'` from another container on `pebble-agent-internal`
returns real results (confirmed with a real query — live repebble.com/pebblecart.com hits for "pebble
smartwatch", same real-result check as `spike-mcp-bridge`'s `mcp-searxng` validation). One non-fatal
warning is expected and harmless: `wikidata: engine init was not successful` (HTTP 403 from that one
upstream engine) — other engines (google cse, duckduckgo, etc.) work fine.

## n8n workflow build (`n8n-workflow-trigger`, `n8n-workflow-agent`)

**`n8n import:workflow` requires a top-level `id` field on the workflow JSON — undocumented in
`--help`, and the error doesn't say so directly.** A workflow JSON with no top-level `id` (just
`name`/`nodes`/`connections`/etc., the way many shared workflow exports look) fails with:
```
null value in column "id" of relation "workflow_entity" violates not-null constraint
```
Fix: include a top-level `"id"` (any unique string works — this project uses a random 16-hex-char
string, not necessarily a full UUID).

**Don't guess node `type`/`typeVersion`/parameter names from memory or docs — read them out of the
running instance instead.** Every n8n node ships a declarative schema at
`.../n8n-nodes-base/dist/node-definitions/nodes/n8n-nodes-base/<nodeName>/v<N>.ts` (and the
`@n8n/n8n-nodes-langchain` equivalent for AI nodes) inside the container, with the exact `type` string,
`typeVersion`, and every parameter name/shape for that version — e.g. find it with `find / -iname
"*McpClientTool*"` inside the container, then read the highest-numbered `vN.ts`. This is how this
project's `n8n/workflows/pebble-index-research-agent.json` was built, and it's why the MCP Client Tool
node uses `serverTransport: "sse"` (default is actually `"httpStreamable"`, which would silently fail
against `mcp-proxy`'s SSE-only endpoints) and why the Agent node's default chat model is `gpt-5-mini`
rather than an older/deprecated one.

**The Local File Trigger node's output only carries `{ event, path }`, not file content.** (Confirmed
from `LocalFileTrigger.node.js`'s `trigger()` implementation — it emits exactly `{ event, path }` per
matched filesystem event, nothing else.) The workflow reads the note's content itself via
**Read/Write Files from Disk** (`operation: "read"`, `fileSelector: "={{ $json.path }}"`) →
**Extract from File** (`operation: "text"`) immediately after the trigger, rather than relying on
`obsidian_read_note` for the very note that triggered the run.

**OpenRouter Chat Model's `model` parameter is a plain string, unlike OpenAI's resource-locator
`{__rl, mode, value}` shape.** Swapped `lmChatOpenAi` for `@n8n/n8n-nodes-langchain.lmChatOpenRouter`
(per user preference — one API key, free choice of any underlying model) partway through building this
workflow. The two nodes' `model` parameter isn't a drop-in match: OpenAI's is a resource-locator object
(`{"__rl": true, "mode": "list", "value": "gpt-5-mini", "cachedResultName": "gpt-5-mini"}`), OpenRouter's
is just `"openai/gpt-5-mini"` (a plain string). Re-used the same credential-omitted pattern (left unset
for the user to attach post-import) and confirmed the swap re-imports and round-trips cleanly.

**The same host directory is mounted at *different* container paths in different services** —
`/vault-mirror` in `n8n` (this project's addition to n8n's own `compose.yml`, read-only) vs. `/vault` in
`mcp-obsidian` (this project's own `docker-compose.yml`). A **Set** node (`Prepare Agent Input`) strips
the `/vault-mirror/` prefix off the trigger's absolute path before handing a vault-*relative* path to
the agent, since `obsidian_create_note`/`obsidian_edit_note` expect paths relative to `mcp-obsidian`'s
own vault root, not n8n's absolute filesystem path.


