#!/usr/bin/env bash
#
# rollback.sh — switch /opt/isales/current back to a prior release on macOS.
#
# Usage:
#     sudo bash deploy/macos/scripts/rollback.sh <release-ts>
#     sudo bash deploy/macos/scripts/rollback.sh --list
#     sudo bash deploy/macos/scripts/rollback.sh <release-ts> --force --dry-run
#
# This script DOES NOT touch the database schema. If the rolled-back release
# expects an older alembic revision, run `alembic downgrade` manually per
# RUNBOOK §rollback-schema.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- args ----------

LIST_ONLY=0
INCLUDE_MODEM=0

mapfile -t REST < <(parse_common_flags "$@")
RELEASE_TS=""
for arg in "${REST[@]+"${REST[@]}"}"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        --include-modem) INCLUDE_MODEM=1 ;;
        --help|-h) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  RELEASE_TS=$arg ;;
    esac
done

CURRENT=/opt/isales/current

# ---------- list mode ----------

if [[ $LIST_ONLY -eq 1 ]]; then
    log_info "available releases under /opt/isales/releases/:"
    if [[ ! -d /opt/isales/releases ]]; then
        log_warn "no releases dir"
        exit 0
    fi
    active=""
    if [[ -L "$CURRENT" ]]; then
        active=$(basename "$(readlink "$CURRENT")")
    fi
    # shellcheck disable=SC2012
    ls -1t /opt/isales/releases | while read -r ts; do
        [[ -n "$ts" ]] || continue
        marker=""
        if [[ "$ts" == "$active" ]]; then marker=" (current)"; fi
        ref=""
        if [[ -d /opt/isales/releases/$ts/isales-common ]]; then
            ref=$(sudo -u "$ISALES_USER" -H git -C "/opt/isales/releases/$ts/isales-common" describe --always --tags 2>/dev/null || echo "")
        fi
        printf '  %s  %s%s\n' "$ts" "$ref" "$marker"
    done
    exit 0
fi

[[ -n "$RELEASE_TS" ]] || die "missing <release-ts> arg. Use --help or --list."

require_macos
require_root

TARGET=/opt/isales/releases/$RELEASE_TS
[[ -d "$TARGET" ]] || die "release does not exist: $TARGET"
[[ -x "$TARGET/venv/bin/python" ]] || die "venv missing in $TARGET (incomplete release)"

if [[ -L "$CURRENT" ]] && [[ "$(readlink "$CURRENT")" == "$TARGET" ]]; then
    die "$CURRENT already points at $TARGET; nothing to rollback"
fi

# ---------- swap + restart ----------

PREV=$(readlink "$CURRENT" 2>/dev/null || echo "<none>")
log_warn "ROLLBACK: $PREV  ->  $TARGET"
log_warn "DB schema will NOT be downgraded. If the older release requires an"
log_warn "older alembic revision, see RUNBOOK §rollback-schema."

if ! confirm "Proceed with rollback?"; then
    die "aborted by user"
fi

run ln -sfn "$TARGET" "$CURRENT"

RESTART_ORDER=(
    com.isales.telephony-api
    com.isales.scheduler
    com.isales.worker
    com.isales.engine
    com.isales.api
)

for label in "${RESTART_ORDER[@]}"; do
    run launchctl kickstart -k "system/$label"
done

run "$BREW_PREFIX/bin/nginx" -t
if [[ $DRY_RUN -eq 1 ]]; then
    log_dry "would: brew services reload nginx (as \$SUDO_USER)"
else
    brew_user=${SUDO_USER:-}
    [[ -n "$brew_user" ]] || die "nginx reload needs SUDO_USER set"
    sudo -u "$brew_user" -H "$BREW_PREFIX/bin/brew" services reload nginx
fi

if [[ $INCLUDE_MODEM -eq 1 ]]; then
    run launchctl kickstart -k "system/com.isales.modem-controller"
else
    log_info "com.isales.modem-controller: skipped (硬件耦合)"
fi

log_info "rollback complete"
log_info "DB schema unchanged. If schema rollback needed, see RUNBOOK §rollback-schema."
