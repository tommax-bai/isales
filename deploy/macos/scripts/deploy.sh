#!/usr/bin/env bash
# macOS ships /bin/bash 3.2 (GPL3-frozen). All scripts here use bash 4+
# features (mapfile, "${arr[@]+...}", etc.). Re-exec under brew bash if
# the current shell is too old.
if [[ ${BASH_VERSINFO[0]:-3} -lt 4 ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
fi
#
# deploy.sh — atomically switch /opt/isales/current and restart launchd
# services on macOS.
#
# Usage:
#     sudo bash deploy/macos/scripts/deploy.sh <release-ts>
#     sudo bash deploy/macos/scripts/deploy.sh <release-ts> --include-modem
#     sudo bash deploy/macos/scripts/deploy.sh <release-ts> --force --dry-run
#
# Restart order (per deployment-topology spec):
#   com.isales.telephony-api → com.isales.scheduler → com.isales.worker
#     → com.isales.engine → com.isales.api
#   nginx: brew services reload nginx
#   com.isales.modem-controller: skipped unless --include-modem (硬件耦合)
#
# Engine restart drops active calls. Outside the low-traffic window
# (default 22:00–08:00 host TZ) deploy.sh refuses to proceed without --force.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- args ----------

INCLUDE_MODEM=0
LOW_PEAK_START=${ISALES_LOW_PEAK_START:-22}
LOW_PEAK_END=${ISALES_LOW_PEAK_END:-8}

parse_common_flags "$@"
RELEASE_TS=""
for arg in "${REST[@]+"${REST[@]}"}"; do
    case "$arg" in
        --include-modem) INCLUDE_MODEM=1 ;;
        --help|-h) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  RELEASE_TS=$arg ;;
    esac
done

[[ -n "$RELEASE_TS" ]] || die "missing <release-ts> arg. Use --help for usage."

require_macos
require_root

RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
CURRENT=/opt/isales/current

[[ -d "$RELEASE_DIR" ]] || die "release dir does not exist: $RELEASE_DIR"
[[ -x "$RELEASE_DIR/venv/bin/python" ]] || die "venv not built at $RELEASE_DIR/venv (run install.sh first)"

# ---------- low-peak gate ----------

is_low_peak() {
    local hour
    hour=$(date +%-H)
    if (( LOW_PEAK_START < LOW_PEAK_END )); then
        (( hour >= LOW_PEAK_START && hour < LOW_PEAK_END ))
    else
        (( hour >= LOW_PEAK_START || hour < LOW_PEAK_END ))
    fi
}

if ! is_low_peak; then
    if [[ $FORCE -eq 0 ]]; then
        die "outside low-peak window (current $(date +%H:%M); window ${LOW_PEAK_START}:00-${LOW_PEAK_END}:00). Engine restart will drop active calls. Pass --force to proceed."
    fi
    log_warn "outside low-peak window; --force given, proceeding (active calls will drop)"
fi

# ---------- step 1: swap symlink ----------

step_symlink() {
    log_info "step 1/3: switch $CURRENT -> $RELEASE_DIR"
    if [[ -L "$CURRENT" ]]; then
        log_info "previous: $(readlink "$CURRENT")"
    fi
    run ln -sfn "$RELEASE_DIR" "$CURRENT"
}

# ---------- step 2: restart services in order ----------

# launchctl labels (no .service suffix on macOS); paired with restart order.
RESTART_ORDER=(
    com.isales.telephony-api
    com.isales.scheduler
    com.isales.worker
    com.isales.engine
    com.isales.api
)

# launchctl_running <label> — returns 0 if `state = running` is reported by
# `launchctl print system/<label>`. macOS 14 prefers `launchctl print` over
# the deprecated `list`; output format is `state = running` (literal text).
launchctl_running() {
    local label=$1
    launchctl print "system/$label" 2>/dev/null | grep -qE '^[[:space:]]+state = running$'
}

# Bootstrap a plist if not already loaded; idempotent.
ensure_bootstrapped() {
    local label=$1
    local plist=/Library/LaunchDaemons/$label.plist
    [[ -f "$plist" ]] || die "missing $plist (run install.sh first)"
    if launchctl print "system/$label" >/dev/null 2>&1; then
        return 0
    fi
    run launchctl bootstrap system "$plist"
}

step_restart() {
    log_info "step 2/3: restart services in dependency order"
    local label
    for label in "${RESTART_ORDER[@]}"; do
        ensure_bootstrapped "$label"
        # `kickstart -k` can race against a freshly-bootstrapped service
        # (process still spawning), returning "Operation not permitted" even
        # though the service is healthy. Tolerate kickstart errors here and
        # let `launchctl_running` below be the source of truth.
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "launchctl kickstart -k system/$label"
        else
            log_info "launchctl kickstart -k system/$label"
            launchctl kickstart -k "system/$label" 2>&1 | sed 's/^/  /' || true
        fi
        if [[ $DRY_RUN -eq 0 ]]; then
            sleep 2
            if ! launchctl_running "$label"; then
                log_err "$label failed to start; recent unified log:"
                log show --predicate "subsystem == \"$label\"" --last 5m --no-pager 2>/dev/null \
                    | tail -50 >&2 || true
                die "$label not running after kickstart"
            fi
        fi
    done

    # Validate nginx config before reload.
    run "$BREW_PREFIX/bin/nginx" -t

    # nginx is owned by the brew user, not root; reload via brew services as
    # the original sudo invoker.
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would: brew services reload nginx (as \$SUDO_USER)"
    else
        local brew_user=${SUDO_USER:-}
        [[ -n "$brew_user" ]] || die "nginx reload needs SUDO_USER set"
        sudo -u "$brew_user" -H "$BREW_PREFIX/bin/brew" services reload nginx
    fi

    if [[ $INCLUDE_MODEM -eq 1 ]]; then
        log_info "restarting com.isales.modem-controller (--include-modem)"
        ensure_bootstrapped com.isales.modem-controller
        run launchctl kickstart -k "system/com.isales.modem-controller"
    else
        log_info "com.isales.modem-controller: skipped (硬件耦合; pass --include-modem to restart)"
    fi
}

# ---------- step 3: summary ----------

step_summary() {
    log_info "step 3/3: deployment summary"
    [[ $DRY_RUN -eq 1 ]] && { log_dry "(dry-run; no service status to read)"; return 0; }
    local label state pid
    for label in "${RESTART_ORDER[@]}" com.isales.modem-controller; do
        if launchctl_running "$label"; then
            state=running
        else
            state=stopped
        fi
        pid=$(launchctl print "system/$label" 2>/dev/null \
            | sed -n 's/^[[:space:]]*pid = \([0-9]*\)$/\1/p' | head -1)
        pid=${pid:-?}
        printf '  %-32s %-10s pid=%s\n' "$label" "$state" "$pid"
    done
}

main() {
    log_info "iSales deploy.sh (macOS): release=$RELEASE_TS, INCLUDE_MODEM=$INCLUDE_MODEM, DRY_RUN=$DRY_RUN, FORCE=$FORCE"
    step_symlink
    step_restart
    step_summary
    log_info "deploy complete"
}

main "$@"
