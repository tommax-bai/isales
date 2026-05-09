#!/usr/bin/env bash
#
# install.sh — build a new release under /opt/isales/releases/<ts>/.
#
# Does NOT touch the `current` symlink — that is deploy.sh's job.
#
# Usage:
#     sudo bash deploy/scripts/install.sh v0.1.0
#     sudo bash deploy/scripts/install.sh main --dry-run
#
# Environment overrides:
#     ISALES_GIT_BASE   default: https://github.com/tommax-bai
#     ISALES_REPOS      space-separated repo list (default: 7 standard repos)
#
# Steps:
#   1. Resolve target release dir /opt/isales/releases/<ts>/
#   2. Clone or update each of the 7 repos into the release dir
#   3. Create a shared venv and pip install -e isales-common + 5 services
#   4. Build isales-web (npm ci && npm run build → dist/)
#   5. Sync systemd units to /etc/systemd/system/ with rewritten ExecStart
#   6. Sync nginx config to /etc/nginx/sites-available/isales
#   7. Write EnvironmentFile drop-ins (one per service unit)
#   8. Sync backup cron to /etc/cron.d/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- args ----------

mapfile -t REST < <(parse_common_flags "$@")

GIT_REF=""
for arg in "${REST[@]:-}"; do
    case "$arg" in
        --help|-h)
            sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) die "unknown flag: $arg" ;;
        *)  GIT_REF=$arg ;;
    esac
done

[[ -n "$GIT_REF" ]] || die "missing <git-ref> arg (e.g. v0.1.0). Use --help for usage."

require_root

GIT_BASE=${ISALES_GIT_BASE:-https://github.com/tommax-bai}
# shellcheck disable=SC2206  # word-split on whitespace is intentional here
REPOS=(${ISALES_REPOS:-isales-common isales-api isales-engine isales-scheduler isales-worker isales-telephony isales-web})

RELEASE_TS=$(date +%Y%m%d-%H%M%S)
RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
VENV_DIR=$RELEASE_DIR/venv

# Trap: clean up incomplete release dir on failure (only if we created it).
TRAP_CLEANUP=0
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]] && [[ $TRAP_CLEANUP -eq 1 ]] && [[ -d "$RELEASE_DIR" ]]; then
        log_err "install failed; cleaning up incomplete release: $RELEASE_DIR"
        rm -rf "$RELEASE_DIR"
    fi
}
trap on_exit EXIT

# ---------- helpers ----------

run_as_isales() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "(as isales) $*"
    else
        log_info "(as isales) $*"
        sudo -u isales -H bash -c "$*"
    fi
}

# ---------- step 1: release dir ----------

step_release_dir() {
    log_info "step 1/8: prepare release dir $RELEASE_DIR"
    run install -d -m 0755 -o isales -g isales "$RELEASE_DIR"
    TRAP_CLEANUP=1
}

# ---------- step 2: clone/update repos ----------

step_clone() {
    log_info "step 2/8: clone/update repos at ref=$GIT_REF"
    local repo url dst
    for repo in "${REPOS[@]}"; do
        url=$GIT_BASE/$repo.git
        dst=$RELEASE_DIR/$repo
        run_as_isales "git clone --depth 50 '$url' '$dst'"
        run_as_isales "cd '$dst' && git fetch --tags origin && git checkout '$GIT_REF'"
    done
}

# ---------- step 3: venv + pip install ----------

step_venv() {
    log_info "step 3/8: create venv + pip install"
    run_as_isales "python3.12 -m venv '$VENV_DIR'"
    run_as_isales "'$VENV_DIR/bin/pip' install --upgrade pip wheel"
    # isales-common first (others depend on it)
    run_as_isales "'$VENV_DIR/bin/pip' install -e '$RELEASE_DIR/isales-common'"
    local svc
    for svc in isales-api isales-engine isales-scheduler isales-worker isales-telephony; do
        run_as_isales "'$VENV_DIR/bin/pip' install -e '$RELEASE_DIR/$svc'"
    done
}

# ---------- step 4: web build ----------

step_web() {
    log_info "step 4/8: build isales-web"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && npm ci"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && npm run build"
    [[ $DRY_RUN -eq 1 ]] || [[ -d "$RELEASE_DIR/isales-web/dist" ]] \
        || die "expected $RELEASE_DIR/isales-web/dist after build"
}

# ---------- step 5: systemd units ----------

# (unit_basename relative_path_in_release)
SYSTEMD_UNITS=(
    "isales-api.service              isales-api/deploy/isales-api.service"
    "isales-engine.service           isales-engine/deploy/isales-engine.service"
    "isales-scheduler.service        isales-scheduler/deploy/isales-scheduler.service"
    "isales-worker.service           isales-worker/deploy/isales-worker.service"
    "isales-telephony-api.service    isales-telephony/deploy/isales-telephony-api.service"
    "isales-modem-controller.service isales-telephony/deploy/isales-modem-controller.service"
)

rewrite_unit() {
    # Rewrite a unit file from the source repo to point at /opt/isales/current/.
    # Service units in the 7 repos drifted to two layouts:
    #   - shared venv:    /opt/isales/venv/bin/X      (api, telephony-{api,modem})
    #   - per-svc venv:   /opt/isales-X/.venv/bin/X   (engine, scheduler, worker)
    # And similarly per-svc WorkingDirectory. We unify everything onto the
    # release-symlink layout so atomic symlink swap controls which release
    # is active.
    sed -E \
        -e 's|ExecStart=/opt/isales/venv/bin/|ExecStart=/opt/isales/current/venv/bin/|g' \
        -e 's|ExecStart=/opt/isales-([a-z]+)/\.venv/bin/|ExecStart=/opt/isales/current/venv/bin/|g' \
        -e 's|WorkingDirectory=/opt/isales-([a-z]+)$|WorkingDirectory=/opt/isales/current/isales-\1|g'
}

step_systemd() {
    log_info "step 5/8: sync systemd units to /etc/systemd/system/"
    local entry unit src dst
    for entry in "${SYSTEMD_UNITS[@]}"; do
        unit=${entry%% *}
        src=$RELEASE_DIR/${entry#* }
        src=${src##* }   # strip leading whitespace runs from the literal table
        dst=/etc/systemd/system/$unit
        [[ -f "$src" ]] || die "missing unit source: $src"
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would install $src -> $dst (rewrite ExecStart + WorkingDirectory)"
            continue
        fi
        rewrite_unit < "$src" > "$dst"
        chmod 0644 "$dst"
        chown root:root "$dst"
        log_info "installed $unit"
    done
    run systemctl daemon-reload
}

# ---------- step 6: nginx ----------

step_nginx() {
    log_info "step 6/8: sync nginx config"
    local src=$RELEASE_DIR/isales-web/deploy/nginx.conf
    local dst=/etc/nginx/sites-available/isales
    [[ -f "$src" ]] || die "missing nginx source: $src"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $src -> $dst + symlink /var/www/isales-web"
        return 0
    fi
    # nginx.conf hardcodes `root /var/www/isales-web;`. Honor it via a symlink
    # to the active release's dist. This keeps nginx.conf source unchanged and
    # makes rollback a symlink swap.
    install -m 0644 -o root -g root "$src" "$dst"
    ln -sfn /opt/isales/current/isales-web/dist /var/www/isales-web
    ln -sfn "$dst" /etc/nginx/sites-enabled/isales
    log_info "installed nginx config + symlinks"
}

# ---------- step 7: EnvironmentFile drop-ins ----------

# unit_basename -> env file basename
ENV_DROPINS=(
    "isales-api.service              api"
    "isales-engine.service           engine"
    "isales-scheduler.service        scheduler"
    "isales-worker.service           worker"
    "isales-telephony-api.service    telephony-api"
    "isales-modem-controller.service modem-controller"
)

step_env_dropins() {
    log_info "step 7/8: write EnvironmentFile drop-ins"
    local entry unit envname dropin_dir conf
    for entry in "${ENV_DROPINS[@]}"; do
        unit=${entry%% *}
        envname=${entry##* }
        dropin_dir=/etc/systemd/system/$unit.d
        conf=$dropin_dir/env.conf

        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would write $conf -> EnvironmentFile=/etc/isales/env/$envname.env"
            continue
        fi
        install -d -m 0755 "$dropin_dir"
        # The empty EnvironmentFile= clears any path baked into the unit by
        # the source repo (some units ship `EnvironmentFile=/etc/isales/X.env`,
        # which is the legacy flat layout). The next line sets our centralized
        # path under /etc/isales/env/.
        cat > "$conf" <<EOF
# Managed by iSales install.sh. Edits will be overwritten on next install.
[Service]
EnvironmentFile=
EnvironmentFile=/etc/isales/env/$envname.env
EOF
        chmod 0644 "$conf"
        log_info "wrote $conf"
    done
    run systemctl daemon-reload
}

# ---------- step 8: backup cron ----------

step_cron() {
    log_info "step 8/8: install backup cron"
    local src=$META_REPO_DIR/deploy/cron/isales-backup.cron
    local dst=/etc/cron.d/isales-backup

    if [[ ! -f "$src" ]]; then
        log_warn "missing $src — skipping cron install (PR #7 lands this file)"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install cron $src -> $dst"
        return 0
    fi
    install -m 0644 -o root -g root "$src" "$dst"
    log_info "installed $dst"
}

# ---------- main ----------

main() {
    log_info "iSales install.sh starting (release=$RELEASE_TS, ref=$GIT_REF, DRY_RUN=$DRY_RUN)"
    step_release_dir
    step_clone
    step_venv
    step_web
    step_systemd
    step_nginx
    step_env_dropins
    step_cron
    TRAP_CLEANUP=0   # success; do not clean
    log_info "install complete: $RELEASE_DIR"
    log_info "next: bash deploy/scripts/migrate.sh && bash deploy/scripts/deploy.sh $RELEASE_TS"
}

main "$@"
