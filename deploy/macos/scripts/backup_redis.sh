#!/usr/bin/env bash
# macOS ships /bin/bash 3.2 (GPL3-frozen). All scripts here use bash 4+
# features (mapfile, "${arr[@]+...}", etc.). Re-exec under brew bash if
# the current shell is too old.
if [[ ${BASH_VERSINFO[0]:-3} -lt 4 ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
fi
#
# backup_redis.sh — daily Redis snapshot on macOS via `redis-cli --rdb`.
# Output: /opt/isales/backups/redis/YYYY-MM-DD.rdb.gz. Retention: 14 days.

set -euo pipefail

BREW_PREFIX=${BREW_PREFIX:-/opt/homebrew}
export PATH="$BREW_PREFIX/bin:/usr/bin:/bin"

BACKUP_DIR=/opt/isales/backups/redis
RETAIN_DAYS=${ISALES_REDIS_BACKUP_RETAIN:-14}
ENV_FILE=${ISALES_ENV_FILE:-/etc/isales/env/api.env}
TS=$(date +%F)
OUT=$BACKUP_DIR/$TS.rdb.gz
TMP_RDB=$(mktemp /tmp/isales-redis.XXXXXX.rdb)

trap 'rm -f "$TMP_RDB" "$OUT.tmp"' EXIT

mkdir -p "$BACKUP_DIR"

if ! command -v redis-cli >/dev/null 2>&1; then
    logger -t isales-backup -p user.err "backup_redis.sh: redis-cli not installed"
    echo "redis-cli not installed" >&2
    exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
    logger -t isales-backup -p user.err "backup_redis.sh: cannot read $ENV_FILE"
    echo "cannot read $ENV_FILE" >&2
    exit 1
fi
URL=$(grep -m1 '^ISALES_REDIS_URL=' "$ENV_FILE" | cut -d= -f2-)
[[ -n "$URL" ]] || { echo "ISALES_REDIS_URL missing in $ENV_FILE" >&2; exit 1; }

HOST=$(printf '%s' "$URL" | sed -E 's|redis://([^@]*@)?([^:/]+).*|\2|')
PORT=$(printf '%s' "$URL" | sed -nE 's|redis://[^/]*:([0-9]+).*|\1|p')
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-6379}

if ! redis-cli -h "$HOST" -p "$PORT" --rdb "$TMP_RDB" 2>/tmp/isales-redis.err; then
    err=$(cat /tmp/isales-redis.err 2>/dev/null || echo "<no stderr>")
    logger -t isales-backup -p user.err "backup_redis.sh: redis-cli --rdb failed: $err"
    echo "redis-cli --rdb failed: $err" >&2
    exit 1
fi

if ! gzip -c "$TMP_RDB" > "$OUT.tmp"; then
    logger -t isales-backup -p user.err "backup_redis.sh: gzip failed"
    echo "gzip failed" >&2
    exit 1
fi
mv "$OUT.tmp" "$OUT"
chmod 0640 "$OUT"

find "$BACKUP_DIR" -maxdepth 1 -name '*.rdb.gz' -mtime +"$RETAIN_DAYS" -delete

logger -t isales-backup -p user.info "backup_redis.sh: ok ($OUT, retain=${RETAIN_DAYS}d)"
echo "ok: $OUT"
