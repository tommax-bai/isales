#!/usr/bin/env bash
#
# rollback.sh — switch /opt/isales/current back to a prior edge release and
# kick the LaunchAgent. State on edge is durable through release swaps:
#   ~/Library/Application Support/isales/sqlite/edge_buffer.db  (WAL DB)
# survives rollback because it lives in user state, not release dir.
#
# Usage:
#     bash deploy/edge/scripts/rollback.sh <release-ts>
#     bash deploy/edge/scripts/rollback.sh --list
#
# Run as the LOGIN USER (not root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../macos/scripts/_lib.sh
source "$META_REPO_DIR/deploy/macos/scripts/_lib.sh"

# ---------- args ----------

LIST_ONLY=0
parse_common_flags "$@"
RELEASE_TS=""
for arg in "${REST[@]:-}"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        --help|-h) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  RELEASE_TS=$arg ;;
    esac
done

CURRENT=/opt/isales/current
LABEL=com.isales.telephony

if [[ $EUID -eq 0 ]]; then
    die "do not run as root; rollback.sh is a per-user operation"
fi

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
            ref=$(git -C "/opt/isales/releases/$ts/isales-common" describe --always --tags 2>/dev/null || echo "")
        fi
        printf '  %s  %s%s\n' "$ts" "$ref" "$marker"
    done
    exit 0
fi

[[ -n "$RELEASE_TS" ]] || die "missing <release-ts>. Use --help or --list."

TARGET=/opt/isales/releases/$RELEASE_TS
[[ -d "$TARGET" ]] || die "release does not exist: $TARGET"
[[ -x "$TARGET/venv/bin/python" ]] || die "venv missing in $TARGET (incomplete release)"

if [[ -L "$CURRENT" ]] && [[ "$(readlink "$CURRENT")" == "$TARGET" ]]; then
    die "$CURRENT already points at $TARGET; nothing to rollback"
fi

PREV=$(readlink "$CURRENT" 2>/dev/null || echo "<none>")
log_warn "ROLLBACK: $PREV  ->  $TARGET"
log_warn "Edge SQLite buffer at ~/Library/Application Support/isales/sqlite/ is preserved."

if ! confirm "Proceed with rollback?"; then
    die "aborted by user"
fi

run ln -sfn "$TARGET" "$CURRENT"

# launchctl kickstart restarts the LaunchAgent in-place; -k forces termination
# of the existing process first.
log_info "kickstarting $LABEL"
run launchctl kickstart -k "gui/$UID/$LABEL"

log_info "rollback complete"
log_info "verify: log stream --predicate 'subsystem == \"isales.telephony\"' --info"
