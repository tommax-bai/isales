#!/usr/bin/env bash
# macOS ships /bin/bash 3.2 (GPL3-frozen). All scripts here use bash 4+
# features (mapfile, "${arr[@]+...}", etc.). Re-exec under brew bash if
# the current shell is too old.
if [[ ${BASH_VERSINFO[0]:-3} -lt 4 ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
fi
#
# provision.sh — one-time host provisioning for iSales on macOS 14+ (Apple Silicon).
#
# Idempotent: re-running on an already-provisioned host MUST NOT reset secrets
# nor reinstall packages. Repeats print "already exists, skipped".
#
# Usage:
#     sudo bash deploy/macos/scripts/provision.sh             # core provision
#     sudo bash deploy/macos/scripts/provision.sh --dry-run   # log only
#
# What it does:
#   1. brew install system packages (postgresql@16 / redis / nginx / ...)
#   2. Create system user `_isales:_isales` (UID 350, shell /usr/bin/false)
#   3. Create directory skeleton under /opt/isales/ and /etc/isales/env/
#   4. Configure Redis AOF persistence (/opt/homebrew/etc/redis.conf)
#   5. Initialize PostgreSQL role + database; generate first random secret
#      and write skeleton env files into /etc/isales/env/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- parse args ----------

parse_common_flags "$@"
for arg in "${REST[@]+"${REST[@]}"}"; do
    case "$arg" in
        --help|-h)
            sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown arg: $arg (use --help)" ;;
    esac
done

require_macos
require_root

# ---------- step 1: brew packages ----------

_brew() {
    # Run brew commands as the original (non-root) user — Homebrew refuses
    # to run as root on macOS. SUDO_USER is set by sudo; if absent (e.g.
    # already root) we cannot proceed because there is no sane brew owner.
    local brew_user=${SUDO_USER:-}
    [[ -n "$brew_user" ]] || die "must invoke via sudo so brew runs as your user (not root)"
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "(as $brew_user) brew $*"
    else
        log_info "(as $brew_user) brew $*"
        sudo -u "$brew_user" -H "$BREW_PREFIX/bin/brew" "$@"
    fi
}

step_brew() {
    log_info "step 1/5: brew install"
    [[ -x "$BREW_PREFIX/bin/brew" ]] || die "Homebrew not found at $BREW_PREFIX/bin/brew (install brew first: https://brew.sh)"

    local pkg
    for pkg in "${MACOS_BREW_PACKAGES[@]}"; do
        # Strip version suffix for the `list` check (postgresql@16 → postgresql@16 is fine,
        # `brew list <name>@<ver>` works directly).
        if sudo -u "${SUDO_USER:-root}" -H "$BREW_PREFIX/bin/brew" list "$pkg" >/dev/null 2>&1; then
            log_info "brew $pkg: already installed, skipped"
        else
            _brew install "$pkg"
        fi
    done
}

# ---------- step 2: _isales user ----------

step_user() {
    log_info "step 2/5: ensure system user '$ISALES_USER'"
    if dscl . -read "/Users/$ISALES_USER" UniqueID >/dev/null 2>&1; then
        log_info "user $ISALES_USER: already exists, skipped"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would create $ISALES_USER (UID $ISALES_USER_UID) + group $ISALES_GROUP (GID $ISALES_USER_GID)"
        return 0
    fi
    # `dscl -create <path> <attr> <value>` errors with eDSRecordAlreadyExists
    # if the attribute already exists (macOS auto-fills some fields when a
    # record is initially created). Force-replace by -delete + -create, with
    # the -delete tolerated when the attribute isn't there yet.
    _dscl_set() {
        local path=$1 attr=$2 value=$3
        dscl . -delete "$path" "$attr" >/dev/null 2>&1 || true
        run dscl . -create "$path" "$attr" "$value"
    }

    # Group first so the user's PrimaryGroupID resolves.
    if ! dscl . -read "/Groups/$ISALES_GROUP" >/dev/null 2>&1; then
        run dscl . -create "/Groups/$ISALES_GROUP"
    fi
    _dscl_set "/Groups/$ISALES_GROUP" PrimaryGroupID "$ISALES_USER_GID"
    _dscl_set "/Groups/$ISALES_GROUP" RealName "iSales service group"

    run dscl . -create "/Users/$ISALES_USER"
    _dscl_set "/Users/$ISALES_USER" UniqueID "$ISALES_USER_UID"
    _dscl_set "/Users/$ISALES_USER" PrimaryGroupID "$ISALES_USER_GID"
    _dscl_set "/Users/$ISALES_USER" UserShell /usr/bin/false
    _dscl_set "/Users/$ISALES_USER" RealName "iSales service account"
    _dscl_set "/Users/$ISALES_USER" NFSHomeDirectory /opt/isales
    _dscl_set "/Users/$ISALES_USER" IsHidden 1
}

# ---------- step 3: directories ----------

ensure_dir() {
    local path=$1 mode=$2 owner=$3
    if [[ -d "$path" ]]; then
        log_info "dir $path: already exists, skipped"
        if [[ $DRY_RUN -eq 0 ]]; then
            chmod "$mode" "$path"
            chown "$owner" "$path"
        fi
    else
        run install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$path"
    fi
}

step_dirs() {
    log_info "step 3/5: create directory skeleton"
    ensure_dir /opt/isales                     0755 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /opt/isales/releases            0755 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /opt/isales/backups             0750 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /opt/isales/backups/pg          0750 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /opt/isales/backups/redis       0750 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /opt/isales/logs                0755 "$ISALES_USER:$ISALES_GROUP"
    ensure_dir /etc/isales                     0750 "root:$ISALES_GROUP"
    ensure_dir /etc/isales/env                 0750 "root:$ISALES_GROUP"
    ensure_dir /var/run/isales                 0755 "$ISALES_USER:$ISALES_GROUP"
}

# ---------- step 4: redis AOF ----------

step_redis() {
    log_info "step 4/5: redis AOF persistence"
    local conf=$BREW_PREFIX/etc/redis.conf

    if [[ ! -f "$conf" ]]; then
        log_warn "$conf not found — brew redis may not be installed; skipping AOF config"
        return 0
    fi

    # Idempotent edit: append our managed block once, identified by sentinel.
    local sentinel="# Managed by iSales provision.sh"
    if grep -q "$sentinel" "$conf" 2>/dev/null; then
        log_info "redis AOF: already configured, skipped"
    elif [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would append AOF block to $conf"
    else
        printf '\n%s\nappendonly yes\nappendfsync everysec\n' "$sentinel" >> "$conf"
        log_info "appended AOF block to $conf"
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        # Activate AOF on the running server via live CONFIG SET.
        #
        # We deliberately avoid `brew services restart redis` here: when this
        # script is invoked under sudo (or via osascript with administrator
        # privileges), brew services falls back to bootstrapping into the
        # `user/<uid>` launchd domain instead of the user's GUI session
        # (`gui/<uid>`). On macOS 14+/26+ that bootstrap path can fail with
        # `Bootstrap failed: 5: Input/output error`, which would abort
        # provisioning. Live `CONFIG SET appendonly yes` + `CONFIG REWRITE`
        # achieves the same effect — Redis re-reads AOF settings without a
        # process restart and persists them to redis.conf.
        local redis_cli=$BREW_PREFIX/bin/redis-cli
        if [[ -x "$redis_cli" ]] && "$redis_cli" ping >/dev/null 2>&1; then
            run "$redis_cli" CONFIG SET appendonly yes
            run "$redis_cli" CONFIG SET appendfsync everysec
            run "$redis_cli" CONFIG REWRITE
        else
            log_warn "redis is not currently running; AOF block in $conf will take effect on next start"
            log_warn "to start redis later: brew services start redis  (run as your user, not via sudo)"
        fi
    fi
}

# ---------- step 5: postgres role + db + secret bootstrap ----------

_psql_as_brew_user() {
    local brew_user=${SUDO_USER:-}
    [[ -n "$brew_user" ]] || die "psql commands must run via sudo with SUDO_USER set"
    sudo -u "$brew_user" -H "$BREW_PREFIX/opt/postgresql@16/bin/psql" "$@"
}

pg_role_exists() {
    _psql_as_brew_user -d postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='isales'" 2>/dev/null | grep -q 1
}

pg_db_exists() {
    _psql_as_brew_user -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='isales'" 2>/dev/null | grep -q 1
}

step_postgres() {
    log_info "step 5/5: postgres role + database"
    require_cmd sudo
    [[ -x "$BREW_PREFIX/opt/postgresql@16/bin/psql" ]] \
        || die "psql not found at $BREW_PREFIX/opt/postgresql@16/bin/psql"

    # postgresql@16 service must be running before we can talk to it.
    if [[ $DRY_RUN -eq 0 ]]; then
        local brew_user=${SUDO_USER:-}
        [[ -n "$brew_user" ]] || die "pg start needs SUDO_USER set"
        sudo -u "$brew_user" -H "$BREW_PREFIX/bin/brew" services start postgresql@16 || true
        # Give the server a moment to come up on a freshly-installed brew.
        sleep 2
    fi

    local pg_pass jwt fernet
    if pg_role_exists; then
        log_info "pg role 'isales': already exists, skipped (password unchanged)"
        if [[ -f /etc/isales/env/api.env ]]; then
            pg_pass=$(grep -m1 '^ISALES_DATABASE_URL=' /etc/isales/env/api.env \
                | sed -n 's|.*://isales:\([^@]*\)@.*|\1|p')
        fi
        pg_pass=${pg_pass:-<unknown-already-set>}
    else
        pg_pass=$(random_secret)
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would CREATE ROLE isales WITH LOGIN PASSWORD <generated>"
        else
            _psql_as_brew_user -d postgres -v ON_ERROR_STOP=1 -c \
                "CREATE ROLE isales WITH LOGIN PASSWORD '$pg_pass'"
        fi
    fi

    if pg_db_exists; then
        log_info "pg db 'isales': already exists, skipped"
    elif [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would CREATE DATABASE isales OWNER isales"
    else
        _psql_as_brew_user -d postgres -v ON_ERROR_STOP=1 -c \
            "CREATE DATABASE isales OWNER isales"
    fi

    jwt=$(random_secret)
    fernet=$("$BREW_PREFIX/opt/python@3.12/bin/python3.12" -c \
        'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' \
        2>/dev/null || echo "")
    fernet=${fernet:-<install-cryptography-and-rerun>}

    local svc
    for svc in api engine scheduler worker telephony-api modem-controller; do
        bootstrap_env_file "$svc" "$pg_pass" "$jwt" "$fernet" \
            "$ISALES_ENV_TEMPLATE_DIR" "root:$ISALES_GROUP"
    done

    log_info "NOTE: edit /etc/isales/env/api.env to set ISALES_ADMIN_USER + ISALES_ADMIN_PASSWORD_HASH before deploy.sh"
}

# ---------- main ----------

main() {
    log_info "iSales provision.sh (macOS) starting (DRY_RUN=$DRY_RUN)"
    step_brew
    step_user
    step_dirs
    step_redis
    step_postgres
    log_info "provision complete. Next: edit /etc/isales/env/*.env, then run install.sh."
}

main "$@"
