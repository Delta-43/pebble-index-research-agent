#!/usr/bin/env bash
# Host-side health check for the Pebble research pipeline. Run it from cron every 15 minutes:
#
#   */15 * * * * /path/to/repo/scripts/pipeline-healthcheck.sh
#
# It checks what n8n cannot check about itself: whether n8n and the other containers are running
# and healthy, whether SearXNG returns results, and whether livesync-cli uploaded the newest
# research note to MinIO. Problems go to the ntfy topic in docker/.env (NTFY_TOPIC). A problem is
# sent once, then again every 6 hours while it lasts, and a recovery message follows when all
# checks pass again. See docs/SETUP.md ("Alerts and health checks").
#
# Limit: this runs on the same server as the pipeline, so it can't report the whole server going
# down. A missing 09:05 summary from the n8n watchdog is the signal for that.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../docker/.env}"
if [ -f "$ENV_FILE" ]; then
  NTFY_TOPIC="${NTFY_TOPIC:-$(grep -E '^NTFY_TOPIC=' "$ENV_FILE" | tail -1 | cut -d= -f2-)}"
  VAULT_MIRROR_PATH="${VAULT_MIRROR_PATH:-$(grep -E '^VAULT_MIRROR_PATH=' "$ENV_FILE" | tail -1 | cut -d= -f2-)}"
fi
: "${NTFY_TOPIC:?Set NTFY_TOPIC in docker/.env}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
VAULT_MIRROR_PATH="${VAULT_MIRROR_PATH:-}"
# Containers that must be running. Names in HEALTHY_CONTAINERS must also report "healthy".
RUNNING_CONTAINERS="${RUNNING_CONTAINERS:-livesync-cli searxng mcp-obsidian mcp-searxng n8n minio cf-minio-tunnel}"
HEALTHY_CONTAINERS="${HEALTHY_CONTAINERS:-searxng mcp-obsidian mcp-searxng n8n minio}"
MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"
MINIO_BUCKET="${MINIO_BUCKET:-obsidian-bucket}"
# Host directory of the LiveSync bucket. The MinIO image has no `find`, so the bucket is read from the
# host side of MinIO's /data bind mount.
MINIO_BUCKET_DIR="${MINIO_BUCKET_DIR:-$(docker inspect "$MINIO_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)/$MINIO_BUCKET}"
SYNC_GRACE_SECONDS="${SYNC_GRACE_SECONDS:-900}"
REALERT_SECONDS="${REALERT_SECONDS:-21600}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pebble-pipeline}"
mkdir -p "$STATE_DIR"

problems=()

# 1. Containers running and healthy.
for c in $RUNNING_CONTAINERS; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null | tr -d '[:space:]')
  state="${state:-missing}"
  if [ "$state" != "running" ]; then
    problems+=("Container $c is $state.")
    continue
  fi
  case " $HEALTHY_CONTAINERS " in
    *" $c "*)
      health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c")
      [ "$health" = "healthy" ] || [ "$health" = "starting" ] || problems+=("Container $c is $health.")
      ;;
  esac
done

# 2. SearXNG returns results (run inside its own container: it is not reachable from the host).
if docker inspect -f '{{.State.Running}}' searxng 2>/dev/null | grep -q true; then
  count=$(docker exec searxng sh -c 'wget -qO- -T 20 "http://localhost:8080/search?q=wikipedia&format=json"' 2>/dev/null \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("results", [])))' 2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ] || problems+=("SearXNG returned no results for a test search. Upstream engines may be blocking the server.")
fi

# 3. livesync-cli uploaded the newest research note. Each upload writes a new journal object to
#    the bucket, so the newest journal must be newer than the newest research note once the grace
#    period has passed.
if [ -n "$VAULT_MIRROR_PATH" ] && [ -d "$VAULT_MIRROR_PATH/Research" ]; then
  note_ts=$(find "$VAULT_MIRROR_PATH/Research" -maxdepth 1 -name '*.md' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
  journal_ts=$(find "$MINIO_BUCKET_DIR" -maxdepth 1 -name '*-docs.jsonl.gz' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
  now=$(date +%s)
  if [ ! -d "$MINIO_BUCKET_DIR" ]; then
    problems+=("Cannot read the MinIO bucket directory ($MINIO_BUCKET_DIR) to check uploads.")
  elif [ -n "$note_ts" ] && [ $((now - note_ts)) -gt "$SYNC_GRACE_SECONDS" ]; then
    if [ -z "$journal_ts" ] || [ "$journal_ts" -lt "$note_ts" ]; then
      problems+=("livesync-cli has not uploaded the newest research note to MinIO after $((SYNC_GRACE_SECONDS / 60)) minutes. Check its logs.")
    fi
  fi
fi

push() { # title, message, priority, tags
  curl -fsS -m 15 -o /dev/null -H "Title: $1" -H "Priority: $3" -H "Tags: $4" -d "$2" "$NTFY_URL/$NTFY_TOPIC" \
    || echo "$(date -Is) ntfy push failed: $1" >&2
}

now=$(date +%s)
if [ ${#problems[@]} -gt 0 ]; then
  message=$(printf '%s\n' "${problems[@]}")
  digest=$(printf '%s' "$message" | sha256sum | cut -c1-16)
  last_digest=$(cat "$STATE_DIR/last_digest" 2>/dev/null || true)
  last_sent=$(cat "$STATE_DIR/last_sent" 2>/dev/null || echo 0)
  if [ "$digest" != "$last_digest" ] || [ $((now - last_sent)) -ge "$REALERT_SECONDS" ]; then
    push "Pebble pipeline: server check failed" "$message" 4 warning
    echo "$digest" > "$STATE_DIR/last_digest"
    echo "$now" > "$STATE_DIR/last_sent"
  fi
  echo "$message"
  exit 1
fi

if [ -s "$STATE_DIR/last_digest" ]; then
  push "Pebble pipeline: server checks pass again" "All server checks pass." 2 white_check_mark
  rm -f "$STATE_DIR/last_digest" "$STATE_DIR/last_sent"
fi
echo "OK"
