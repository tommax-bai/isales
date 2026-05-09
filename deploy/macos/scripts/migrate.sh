#!/usr/bin/env bash
#
# migrate.sh — run alembic upgrade head against the active release on macOS.
#
# Decoupled from install.sh so rollbacks can choose to skip schema changes.
# Reads ISALES_DATABASE_URL from /etc/isales/env/api.env (any service env
# would do; we use api.env by convention).
#
# Usage:
#     sudo bash deploy/macos/scripts/migrate.sh              # upgrade head
#     sudo bash deploy/macos/scripts/migrate.sh --dry-run    # alembic history -i
#
# Always operates on /opt/isales/current.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

mapfile -t REST < <(parse_common_flags "$@")
for arg in "${REST[@]+"${REST[@]}"}"; do
    case "$arg" in
        --help|-h) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown arg: $arg" ;;
    esac
done

require_macos
require_root

CURRENT=/opt/isales/current
ENV_FILE=/etc/isales/env/api.env

[[ -L "$CURRENT" ]] || die "$CURRENT does not exist; run install.sh + deploy.sh first"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE missing; run provision.sh first"

ALEMBIC=$CURRENT/venv/bin/alembic
ALEMBIC_INI=$CURRENT/isales-common/alembic.ini

[[ -x "$ALEMBIC" ]] || die "alembic not executable at $ALEMBIC"
[[ -f "$ALEMBIC_INI" ]] || die "alembic.ini missing at $ALEMBIC_INI"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ $DRY_RUN -eq 1 ]]; then
    log_info "dry-run: alembic history -i"
    sudo -u "$ISALES_USER" -H \
        env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
        "$ALEMBIC" -c "$ALEMBIC_INI" history -i
else
    log_info "running alembic upgrade head"
    sudo -u "$ISALES_USER" -H \
        env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
        "$ALEMBIC" -c "$ALEMBIC_INI" upgrade head
    log_info "alembic upgrade complete"
fi
