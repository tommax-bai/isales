#!/usr/bin/env bash
#
# deploy.sh — atomically switch /opt/isales/current and restart services.
#
# Usage:
#     sudo bash deploy/scripts/deploy.sh <release-ts>
#     sudo bash deploy/scripts/deploy.sh <release-ts> --include-modem
#     sudo bash deploy/scripts/deploy.sh <release-ts> --force --dry-run
#
# Restart order (per deployment-topology spec):
#   isales-telephony-api → isales-scheduler → isales-worker → isales-engine → isales-api
#   nginx: reload (not restart)
#   isales-modem-controller: skipped unless --include-modem (硬件耦合)
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

mapfile -t REST < <(parse_common_flags "$@")
RELEASE_TS=""
for arg in "${REST[@]:-}"; do
    case "$arg" in
        --include-modem) INCLUDE_MODEM=1 ;;
        --help|-h) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  RELEASE_TS=$arg ;;
    esac
done

[[ -n "$RELEASE_TS" ]] || die "missing <release-ts> arg. Use --help for usage."

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

RESTART_ORDER=(
    isales-telephony-api
    isales-scheduler
    isales-worker
    isales-engine
    isales-api
)

step_restart() {
    log_info "step 2/3: restart services in dependency order"
    local svc
    for svc in "${RESTART_ORDER[@]}"; do
        run systemctl restart "$svc.service"
        if [[ $DRY_RUN -eq 0 ]]; then
            sleep 1
            if ! systemctl is-active --quiet "$svc.service"; then
                log_err "$svc failed to start; recent journal:"
                journalctl -u "$svc.service" -n 50 --no-pager >&2 || true
                die "$svc not active after restart"
            fi
        fi
    done

    run nginx -t
    run systemctl reload nginx

    if [[ $INCLUDE_MODEM -eq 1 ]]; then
        log_info "restarting isales-modem-controller (--include-modem)"
        run systemctl restart isales-modem-controller.service
    else
        log_info "isales-modem-controller: skipped (硬件耦合; pass --include-modem to restart)"
    fi
}

# ---------- step 3: summary ----------

step_summary() {
    log_info "step 3/3: deployment summary"
    [[ $DRY_RUN -eq 1 ]] && { log_dry "(dry-run; no service status to read)"; return 0; }
    local svc
    for svc in "${RESTART_ORDER[@]}" isales-modem-controller; do
        local state pid
        state=$(systemctl is-active "$svc.service" 2>/dev/null || echo "?")
        pid=$(systemctl show -p MainPID --value "$svc.service" 2>/dev/null || echo "?")
        printf '  %-30s %-10s pid=%s\n' "$svc" "$state" "$pid"
    done
}

main() {
    log_info "iSales deploy.sh: release=$RELEASE_TS, INCLUDE_MODEM=$INCLUDE_MODEM, DRY_RUN=$DRY_RUN, FORCE=$FORCE"
    step_symlink
    step_restart
    step_summary
    log_info "deploy complete"
}

main "$@"
