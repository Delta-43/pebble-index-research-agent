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

