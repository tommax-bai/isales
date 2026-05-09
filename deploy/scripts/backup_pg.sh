#!/usr/bin/env bash
#
# backup_pg.sh — daily PostgreSQL backup. Triggered by cron (see
# deploy/cron/isales-backup.cron). Output: /opt/isales/backups/pg/YYYY-MM-DD.sql.gz
# Retention: last 14 days. Failure: log to syslog.

set -euo pipefail

BACKUP_DIR=/opt/isales/backups/pg
RETAIN_DAYS=${ISALES_PG_BACKUP_RETAIN:-14}
ENV_FILE=${ISALES_ENV_FILE:-/etc/isales/env/api.env}
TS=$(date +%F)
OUT=$BACKUP_DIR/$TS.sql.gz

mkdir -p "$BACKUP_DIR"

if ! command -v pg_dump >/dev/null 2>&1; then
    logger -t isales-backup -p user.err "backup_pg.sh: pg_dump not installed"
    echo "pg_dump not installed" >&2
    exit 1
fi

# Read ISALES_DATABASE_URL from /etc/isales/env/api.env (group-readable by
# isales). Strip the asyncpg driver suffix so pg_dump (libpq) accepts it.
if [[ ! -r "$ENV_FILE" ]]; then
    logger -t isales-backup -p user.err "backup_pg.sh: cannot read $ENV_FILE"
    echo "cannot read $ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
ASYNC_URL=$(grep -m1 '^ISALES_DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)
PG_URL=${ASYNC_URL/postgresql+asyncpg:/postgresql:}
[[ -n "$PG_URL" ]] || { echo "ISALES_DATABASE_URL missing in $ENV_FILE" >&2; exit 1; }

if ! pg_dump --format=custom --dbname="$PG_URL" 2>/tmp/isales-pgdump.err | gzip > "$OUT.tmp"; then
    err=$(cat /tmp/isales-pgdump.err 2>/dev/null || echo "<no stderr>")
    rm -f "$OUT.tmp"
    logger -t isales-backup -p user.err "backup_pg.sh: pg_dump failed: $err"
    echo "pg_dump failed: $err" >&2
    exit 1
fi
mv "$OUT.tmp" "$OUT"
chmod 0640 "$OUT"

# Retention
find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz' -mtime +"$RETAIN_DAYS" -delete

logger -t isales-backup -p user.info "backup_pg.sh: ok ($OUT, retain=${RETAIN_DAYS}d)"
echo "ok: $OUT"
