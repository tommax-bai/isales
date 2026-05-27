#!/usr/bin/env bash
#
# rollback.sh — switch /opt/isales/current back to a prior cloud release.
#
# Cloud-edge variant of deploy/linux/scripts/rollback.sh:
#   - restarts only the 4 cloud services (api/engine/scheduler/worker)
#   - does NOT touch modem-controller / telephony-api (those live on the edge)
#   - reloads nginx after symlink swap
#   - does NOT touch the database schema; see RUNBOOK-cloud §rollback-schema
#
# Usage:
#     sudo bash deploy/cloud/scripts/rollback.sh <release-ts>
#     sudo bash deploy/cloud/scripts/rollback.sh --list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../linux/scripts/_lib.sh
source "$META_REPO_DIR/deploy/linux/scripts/_lib.sh"

# ---------- args ----------

LIST_ONLY=0
parse_common_flags "$@"
RELEASE_TS=""
for arg in "${REST[@]:-}"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        --help|-h) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  RELEASE_TS=$arg ;;
    esac
done

CURRENT=/opt/isales/current

# ---------- list ----------

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
            ref=$(sudo -u isales -H git -C "/opt/isales/releases/$ts/isales-common" describe --always --tags 2>/dev/null || echo "")
        fi
        printf '  %s  %s%s\n' "$ts" "$ref" "$marker"
    done
    exit 0
fi

[[ -n "$RELEASE_TS" ]] || die "missing <release-ts>. Use --help or --list."

require_root

TARGET=/opt/isales/releases/$RELEASE_TS
[[ -d "$TARGET" ]] || die "release does not exist: $TARGET"
[[ -x "$TARGET/venv/bin/python" ]] || die "venv missing in $TARGET (incomplete release)"
# DingRTC SDK is OS-level (/opt/isales/vendor/DingRTC_Linux_SDK_*/) not per-release,
# so a release rollback does not need to re-check vendor inside $TARGET. The pybind
# binding `dingrtc_pywrap*.so` is built into $TARGET/venv/ by install.sh step 5/8b
# and is therefore release-pinned — if it's missing, the engine will fail to import.
if ! find "$TARGET/venv" -name 'dingrtc_pywrap*.so' -print -quit | grep -q .; then
    log_warn "TARGET venv lacks dingrtc_pywrap*.so — engine will FAIL to import; re-run install.sh on this release"
fi
if ! find /opt/isales/vendor -maxdepth 1 -type d -name 'DingRTC_Linux_SDK_*' -print -quit | grep -q .; then
    log_warn "no DingRTC SDK at /opt/isales/vendor/DingRTC_Linux_SDK_* — engine will FAIL to load; run install-dingrtc-sdk.sh"
fi

if [[ -L "$CURRENT" ]] && [[ "$(readlink "$CURRENT")" == "$TARGET" ]]; then
    die "$CURRENT already points at $TARGET; nothing to rollback"
fi

PREV=$(readlink "$CURRENT" 2>/dev/null || echo "<none>")
log_warn "ROLLBACK: $PREV  ->  $TARGET"
log_warn "DB schema will NOT be downgraded. See RUNBOOK-cloud §rollback-schema."

if ! confirm "Proceed with rollback?"; then
    die "aborted by user"
fi

run ln -sfn "$TARGET" "$CURRENT"

# Restart in dependency-aware order: edge-facing services (engine) last so
# that mid-flight gRPC streams from edges are dropped only once everything
# downstream is ready to accept reconnections.
RESTART_ORDER=(
    isales-scheduler
    isales-worker
    isales-api
    isales-engine
)
for svc in "${RESTART_ORDER[@]}"; do
    run systemctl restart "$svc.service"
done

run nginx -t
run systemctl reload nginx

log_info "rollback complete"
log_info "Edge devices auto-reconnect; mid-flight calls may drop (RTC room is independent)."
