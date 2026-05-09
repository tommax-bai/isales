#!/usr/bin/env bash
#
# provision.sh — one-time host provisioning for iSales v1 single-host deployment.
#
# Idempotent: re-running on an already-provisioned host MUST NOT reset secrets
# nor reinstall packages. Repeats print "already exists, skipped".
#
# Usage:
#     sudo bash deploy/scripts/provision.sh             # core provision
#     sudo bash deploy/scripts/provision.sh --with-modem  # also install udev rules
#     sudo bash deploy/scripts/provision.sh --dry-run   # log only, no changes
#
# What it does:
#   1. apt install system packages (postgresql-15 / redis-server / nginx / ...)
#   2. Create system user `isales:isales` (no shell)
#   3. Create directory skeleton under /opt/isales/ and /etc/isales/env/
#   4. Configure Redis AOF persistence
#   5. Initialize PostgreSQL role + database; generate first random secret
#      and write skeleton env files into /etc/isales/env/
#   6. (--with-modem) install udev rules + reload udev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- parse args ----------

WITH_MODEM=0
mapfile -t REST < <(parse_common_flags "$@")
for arg in "${REST[@]:-}"; do
    case "$arg" in
        --with-modem) WITH_MODEM=1 ;;
        --help|-h)
            sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown arg: $arg (use --help)" ;;
    esac
done

require_root

# ---------- step 1: apt packages ----------

APT_PACKAGES=(
    postgresql-15
    redis-server
    nginx
    git
    pkg-config
    libudev-dev
    libasound2-dev
    python3.12
    python3.12-venv
    nodejs
    npm
    curl
    ca-certificates
)

step_apt() {
    log_info "step 1/6: apt install"
    run apt-get update -qq
    run apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
}

# ---------- step 2: isales user ----------

step_user() {
    log_info "step 2/6: ensure system user 'isales'"
    if id -u isales >/dev/null 2>&1; then
        log_info "user isales: already exists, skipped"
    else
        run useradd --system --no-create-home \
            --home-dir /opt/isales \
            --shell /usr/sbin/nologin \
            --comment 'iSales service account' \
            isales
    fi
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
    log_info "step 3/6: create directory skeleton"
    ensure_dir /opt/isales                     0755 isales:isales
    ensure_dir /opt/isales/releases            0755 isales:isales
    ensure_dir /opt/isales/backups             0750 isales:isales
    ensure_dir /opt/isales/backups/pg          0750 isales:isales
    ensure_dir /opt/isales/backups/redis       0750 isales:isales
    ensure_dir /opt/isales/logs                0755 isales:isales
    ensure_dir /etc/isales                     0750 root:isales
    ensure_dir /etc/isales/env                 0750 root:isales
    ensure_dir /var/run/isales                 0755 isales:isales
}

# ---------- step 4: redis AOF ----------

step_redis() {
    log_info "step 4/6: redis AOF persistence"
    local conf=/etc/redis/redis.conf.d/isales.conf
    install -d -m 0755 /etc/redis/redis.conf.d 2>/dev/null || true

    if grep -q '^include /etc/redis/redis.conf.d/' /etc/redis/redis.conf 2>/dev/null; then
        log_info "redis.conf: include directive already present, skipped"
    elif [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would append 'include /etc/redis/redis.conf.d/*.conf' to /etc/redis/redis.conf"
    elif [[ -f /etc/redis/redis.conf ]]; then
        printf '\n# Added by iSales provision.sh\ninclude /etc/redis/redis.conf.d/*.conf\n' \
            >> /etc/redis/redis.conf
        log_info "appended include directive to /etc/redis/redis.conf"
    fi

    write_file "$conf" 0644 root:root <<'EOF'
# Managed by iSales provision.sh. Edit will be overwritten on re-provision.
appendonly yes
appendfsync everysec
EOF

    if [[ $DRY_RUN -eq 0 ]]; then
        if systemctl is-active --quiet redis-server; then
            run systemctl reload redis-server || run systemctl restart redis-server
        else
            run systemctl enable --now redis-server
        fi
    fi
}

# ---------- step 5: postgres role + db + secret bootstrap ----------

pg_role_exists() {
    sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='isales'" 2>/dev/null | grep -q 1
}

pg_db_exists() {
    sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='isales'" 2>/dev/null | grep -q 1
}

random_secret() {
    # 32 url-safe base64 chars (~190 bits entropy).
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
}

bootstrap_env_file() {
    # bootstrap_env_file <name> <pg-pass>
    # Copies deploy/env/<name>.env.example to /etc/isales/env/<name>.env if
    # missing, substituting <change-me> placeholders for the *first* PG/JWT/
    # FERNET secret. Re-running MUST NOT reset existing files.
    local name=$1 pgpass=$2 jwt=$3 fernet=$4
    local target=/etc/isales/env/$name.env
    local tpl=$SCRIPT_DIR/../env/$name.env.example

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

    install -m 0640 -o root -g isales /dev/null "$target"
    sed \
        -e "s|isales:<change-me>@|isales:${pgpass}@|" \
        -e "s|^ISALES_JWT_SECRET=<change-me>$|ISALES_JWT_SECRET=${jwt}|" \
        -e "s|^ISALES_FERNET_KEY=<change-me>$|ISALES_FERNET_KEY=${fernet}|" \
        "$tpl" > "$target"
    log_info "wrote $target (placeholders for ADMIN_USER / ADMIN_PASSWORD_HASH still need editing)"
}

step_postgres() {
    log_info "step 5/6: postgres role + database"
    require_cmd psql sudo

    local pg_pass jwt fernet
    if pg_role_exists; then
        log_info "pg role 'isales': already exists, skipped (password unchanged)"
        # Read existing pg password from already-provisioned api.env if present
        if [[ -f /etc/isales/env/api.env ]]; then
            pg_pass=$(grep -m1 '^ISALES_DATABASE_URL=' /etc/isales/env/api.env \
                | sed -n 's|.*://isales:\([^@]*\)@.*|\1|p')
        fi
        pg_pass=${pg_pass:-<unknown-already-set>}
    else
        pg_pass=$(random_secret)
        run sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
            "CREATE ROLE isales WITH LOGIN PASSWORD '$pg_pass'"
    fi

    if pg_db_exists; then
        log_info "pg db 'isales': already exists, skipped"
    else
        run sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
            "CREATE DATABASE isales OWNER isales"
    fi

    # JWT + Fernet keys: also one-time generation; only used if env file doesn't
    # exist yet. If env file already exists, secrets are kept (idempotent).
    jwt=$(random_secret)
    if command -v python3 >/dev/null 2>&1; then
        fernet=$(python3 -c \
            'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' \
            2>/dev/null || echo "")
    fi
    fernet=${fernet:-<install-cryptography-and-rerun>}

    bootstrap_env_file api              "$pg_pass" "$jwt" "$fernet"
    bootstrap_env_file engine           "$pg_pass" "$jwt" "$fernet"
    bootstrap_env_file scheduler        "$pg_pass" "$jwt" "$fernet"
    bootstrap_env_file worker           "$pg_pass" "$jwt" "$fernet"
    bootstrap_env_file telephony-api    "$pg_pass" "$jwt" "$fernet"
    bootstrap_env_file modem-controller "$pg_pass" "$jwt" "$fernet"

    log_info "NOTE: edit /etc/isales/env/api.env to set ISALES_ADMIN_USER + ISALES_ADMIN_PASSWORD_HASH before deploy.sh"
}

# ---------- step 6: udev rules (optional) ----------

step_udev() {
    if [[ $WITH_MODEM -eq 0 ]]; then
        log_info "step 6/6: udev rules — skipped (use --with-modem to enable)"
        return 0
    fi
    log_info "step 6/6: install udev rules from isales-telephony"

    # The rules file ships in isales-telephony/deploy/. We resolve it via the
    # current release if /opt/isales/current is set up; otherwise instruct the
    # operator to run install.sh first.
    local rules_src=/opt/isales/current/isales-telephony/deploy/99-isales-modem.rules
    if [[ ! -f "$rules_src" ]]; then
        log_warn "$rules_src not found; run install.sh first, then re-run with --with-modem"
        return 0
    fi
    run install -m 0644 -o root -g root "$rules_src" /etc/udev/rules.d/99-isales-modem.rules
    run udevadm control --reload-rules
    run udevadm trigger
}

# ---------- main ----------

main() {
    log_info "iSales provision.sh starting (DRY_RUN=$DRY_RUN, WITH_MODEM=$WITH_MODEM)"
    step_apt
    step_user
    step_dirs
    step_redis
    step_postgres
    step_udev
    log_info "provision complete. Next: edit /etc/isales/env/*.env, then run install.sh."
}

main "$@"
