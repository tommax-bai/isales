# shellcheck shell=bash
# Shared helpers for deploy/scripts/*.sh. Source this from each script.
#
# Usage:
#     # shellcheck source=./_lib.sh
#     source "$(dirname "$0")/_lib.sh"
#
# Provides:
#   DRY_RUN (0/1) — set by parse_common_flags when --dry-run is passed
#   FORCE   (0/1) — set by parse_common_flags when --force is passed
#   log_info / log_warn / log_err / die
#   require_cmd / require_root / require_user
#   confirm
#   run     — echo + execute (or echo-only under DRY_RUN)
#   write_file — idempotent file write with 0640 default

set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
FORCE=${FORCE:-0}

# ---------- logging ----------

_color() {
    if [[ -t 2 ]]; then printf '\033[%sm' "$1" >&2; fi
}
_reset() { _color 0; }

log_info()  { _color "0;36"; printf '[info]  %s\n' "$*" >&2; _reset; }
log_warn()  { _color "1;33"; printf '[warn]  %s\n' "$*" >&2; _reset; }
log_err()   { _color "1;31"; printf '[err]   %s\n' "$*" >&2; _reset; }
log_dry()   { _color "0;90"; printf '[dry]   %s\n' "$*" >&2; _reset; }

die() {
    log_err "$*"
    exit 1
}

# ---------- arg parsing ----------

parse_common_flags() {
    # Pop --dry-run / --force out of "$@" by re-emitting non-flag args.
    # Caller must use:  set -- "$(parse_common_flags "$@")"  — but bash word-splitting
    # makes that brittle. Instead we modify two globals (DRY_RUN, FORCE) and
    # echo the remaining argv via mapfile. Callers do:
    #     mapfile -t REST < <(parse_common_flags "$@")
    #     set -- "${REST[@]}"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --force)   FORCE=1 ;;
            *)         printf '%s\n' "$arg" ;;
        esac
    done
}

# ---------- guards ----------

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (or via sudo)"
}

require_user() {
    local want=$1
    [[ "$(id -un)" == "$want" ]] || die "must run as user '$want' (current: $(id -un))"
}

confirm() {
    # confirm "Question?" — returns 0 if user types y/yes (or FORCE=1), else 1.
    local prompt=$1 reply
    if [[ $FORCE -eq 1 ]]; then
        log_info "[--force] auto-yes: $prompt"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would prompt: $prompt"
        return 0
    fi
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- effects ----------

run() {
    # run <cmd> <args...>  — log + execute, or log-only if DRY_RUN
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "$*"
        return 0
    fi
    log_info "$*"
    "$@"
}

write_file() {
    # write_file <path> <mode> <owner:group> <<<"contents"
    # Idempotent: only writes if file is missing OR contents differ. Always
    # enforces mode + owner.
    local path=$1 mode=$2 ownergroup=$3
    local content
    content=$(cat)

    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
        log_info "$path: already up to date"
    else
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would write $path (${#content} bytes)"
        else
            log_info "writing $path"
            install -m "$mode" -o "${ownergroup%%:*}" -g "${ownergroup##*:}" /dev/null "$path"
            printf '%s' "$content" > "$path"
        fi
    fi

    if [[ $DRY_RUN -eq 0 ]] && [[ -f "$path" ]]; then
        chmod "$mode" "$path"
        chown "$ownergroup" "$path"
    fi
}
