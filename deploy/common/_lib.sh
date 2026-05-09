# shellcheck shell=bash
# Shared helpers for deploy/{linux,macos}/scripts/*.sh.
# Source this from a per-platform _lib.sh; do not source it directly from
# top-level scripts.
#
# Provides:
#   DRY_RUN (0/1) — set by parse_common_flags when --dry-run is passed
#   FORCE   (0/1) — set by parse_common_flags when --force is passed
#   ISALES_PLATFORM — "linux" or "macos" (set by per-platform _lib.sh before
#                     sourcing this file; defaults to autodetect)
#   log_info / log_warn / log_err / log_dry / die
#   parse_common_flags
#   require_cmd / require_root / require_user
#   confirm
#   run     — echo + execute (or echo-only under DRY_RUN)
#   write_file — idempotent file write with fixed mode + owner
#   bootstrap_env_file — render /etc/isales/env/<name>.env from template (one-time)
#   random_secret — 32 url-safe base64 chars (~190 bits entropy)

set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
FORCE=${FORCE:-0}

if [[ -z "${ISALES_PLATFORM:-}" ]]; then
    case "$(uname -s)" in
        Linux)  ISALES_PLATFORM=linux ;;
        Darwin) ISALES_PLATFORM=macos ;;
        *)      ISALES_PLATFORM=unknown ;;
    esac
fi

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
    # Set DRY_RUN / FORCE globals from "$@"; non-flag args go into the global
    # REST array. Callers do:
    #     parse_common_flags "$@"
    #     for arg in "${REST[@]+"${REST[@]}"}"; do ...; done
    #
    # Note: this CANNOT be invoked via process substitution (e.g.
    # `mapfile -t X < <(parse_common_flags "$@")`) — that would run the body
    # in a subshell and the global mutations would not propagate back.
    REST=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --force)   FORCE=1 ;;
            *)         REST+=("$arg") ;;
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

# ---------- env bootstrap ----------

random_secret() {
    # 32 url-safe base64 chars (~190 bits entropy).
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
}

bootstrap_env_file() {
    # bootstrap_env_file <name> <pgpass> <jwt> <fernet> <env_template_dir> <target_owner>
    # Copies <env_template_dir>/<name>.env.example to /etc/isales/env/<name>.env
    # if missing, substituting <change-me> placeholders. Re-running MUST NOT
    # reset existing files.
    local name=$1 pgpass=$2 jwt=$3 fernet=$4 tpl_dir=$5 target_owner=$6
    local target=/etc/isales/env/$name.env
    local tpl=$tpl_dir/$name.env.example

    if [[ ! -f "$tpl" ]]; then
        log_warn "missing template: $tpl (skip)"
        return 0
    fi
    if [[ -f "$target" ]]; then
        log_info "$target: already exists, skipped (will not reset secrets)"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would create $target from $tpl"
        return 0
    fi

    install -m 0640 -o "${target_owner%%:*}" -g "${target_owner##*:}" /dev/null "$target"
    sed \
        -e "s|isales:<change-me>@|isales:${pgpass}@|" \
        -e "s|^ISALES_JWT_SECRET=<change-me>$|ISALES_JWT_SECRET=${jwt}|" \
        -e "s|^ISALES_FERNET_KEY=<change-me>$|ISALES_FERNET_KEY=${fernet}|" \
        "$tpl" > "$target"
    log_info "wrote $target (placeholders for ADMIN_USER / ADMIN_PASSWORD_HASH still need editing)"
}
