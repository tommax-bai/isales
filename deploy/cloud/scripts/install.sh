#!/usr/bin/env bash
#
# install.sh — cloud-side install for the A2 cloud-edge split topology.
# Replaces deploy/linux/scripts/install.sh for the cloud half: 4 services
# (api/engine/scheduler/worker) + isales-web nginx; no modem-controller,
# no telephony-api.
#
# Usage:
#     sudo bash deploy/cloud/scripts/install.sh v1.0.0
#     sudo bash deploy/cloud/scripts/install.sh main --dry-run
#     sudo bash deploy/cloud/scripts/install.sh --activate 20260515-103000
#
# Environment overrides:
#     ISALES_GIT_BASE   default: https://github.com/tommax-bai
#     ISALES_REPOS      space-separated cloud repos
#                       (default: isales-common isales-api isales-engine
#                                 isales-scheduler isales-worker isales-web)
#     ISALES_DOMAIN     required for nginx.conf rewrite; e.g. cloud.isales.example.com
#
# Steps:
#   1. Resolve target release dir /opt/isales/releases/<ts>/
#   2. Clone or update each cloud repo into the release dir
#   3. Create shared venv; pip install -e isales-common + 4 cloud services
#   4. Build isales-web
#   5. Install DingRTC Linux SDK under OS-level /opt/isales/vendor/ (delegates to
#      install-dingrtc-sdk.sh) and build the project-internal pybind11 binding into the
#      release venv (delegates to isales-engine/deploy/cloud/scripts/build-dingrtc-binding.sh).
#   6. Sync systemd units from deploy/cloud/systemd/ to /etc/systemd/system/
#   7. Sync nginx config (deploy/cloud/nginx/isales.conf with __ISALES_DOMAIN__ rewrite)
#   8. Write EnvironmentFile drop-ins
#   9. (Optional with --activate) swap /opt/isales/current symlink and restart services
#
# Database migrations: run separately via deploy/linux/scripts/migrate.sh (cloud-edge
# does not change the alembic flow).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../linux/scripts/_lib.sh
source "$META_REPO_DIR/deploy/linux/scripts/_lib.sh"

# ---------- args ----------

parse_common_flags "$@"

GIT_REF=""
ACTIVATE_TS=""
ACTIVATE_MODE=0

for arg in "${REST[@]:-}"; do
    case "$arg" in
        --activate) shift; ACTIVATE_TS=$1; ACTIVATE_MODE=1 ;;
        --activate=*) ACTIVATE_TS=${arg#--activate=}; ACTIVATE_MODE=1 ;;
        --help|-h) sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  GIT_REF=$arg ;;
    esac
done

require_root

# ---------- activate-only branch ----------

CURRENT=/opt/isales/current
RESTART_ORDER=(isales-scheduler isales-worker isales-engine isales-api)

activate_release() {
    local ts=$1
    local target=/opt/isales/releases/$ts
    [[ -d "$target" ]] || die "release does not exist: $target"
    [[ -x "$target/venv/bin/python" ]] || die "venv missing in $target (incomplete release)"

    local prev
    prev=$(readlink "$CURRENT" 2>/dev/null || echo "<none>")
    log_info "activate: $prev -> $target"
    run ln -sfn "$target" "$CURRENT"

    # DingRTC SDK is OS-level (/opt/isales/vendor/DingRTC_Linux_SDK_*/) not
    # per-release, so an `--activate` switch never needs to re-fetch it.
    # If the SDK dir is missing entirely (fresh box), fall back to
    # re-running install-dingrtc-sdk.sh; otherwise it's already in place.
    if ! ls -d /opt/isales/vendor/DingRTC_Linux_SDK_* >/dev/null 2>&1; then
        log_warn "no DingRTC SDK at /opt/isales/vendor/DingRTC_Linux_SDK_* — running install-dingrtc-sdk.sh"
        run sudo -u isales bash "$SCRIPT_DIR/install-dingrtc-sdk.sh"
    fi

    for svc in "${RESTART_ORDER[@]}"; do
        run systemctl restart "$svc.service"
    done
    run nginx -t
    run systemctl reload nginx
    log_info "activation complete"
}

if [[ $ACTIVATE_MODE -eq 1 ]]; then
    [[ -n "$ACTIVATE_TS" ]] || die "missing --activate <release-ts>"
    activate_release "$ACTIVATE_TS"
    exit 0
fi

# ---------- install branch ----------

[[ -n "$GIT_REF" ]] || die "missing <git-ref> arg (e.g. v1.0.0). Use --help."
[[ -n "${ISALES_DOMAIN:-}" ]] || die "ISALES_DOMAIN env var required (nginx.conf rewrite)"

GIT_BASE=${ISALES_GIT_BASE:-https://github.com/tommax-bai}
# shellcheck disable=SC2206
REPOS=(${ISALES_REPOS:-isales-common isales-api isales-engine isales-scheduler isales-worker isales-web})

RELEASE_TS=$(date +%Y%m%d-%H%M%S)
RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
VENV_DIR=$RELEASE_DIR/venv

TRAP_CLEANUP=0
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]] && [[ $TRAP_CLEANUP -eq 1 ]] && [[ -d "$RELEASE_DIR" ]]; then
        log_err "install failed; cleaning up incomplete release: $RELEASE_DIR"
        rm -rf "$RELEASE_DIR"
    fi
}
trap on_exit EXIT

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

# ---------- step 2: clone ----------

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

# ---------- step 3: venv ----------

step_venv() {
    log_info "step 3/8: create venv + pip install"
    run_as_isales "python3.12 -m venv '$VENV_DIR'"
    run_as_isales "'$VENV_DIR/bin/pip' install --upgrade pip wheel"
    run_as_isales "'$VENV_DIR/bin/pip' install -e '$RELEASE_DIR/isales-common'"
    local svc
    for svc in isales-api isales-engine isales-scheduler isales-worker; do
        run_as_isales "'$VENV_DIR/bin/pip' install -e '$RELEASE_DIR/$svc'"
    done
}

# ---------- step 4: web ----------

step_web() {
    log_info "step 4/8: build isales-web"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && npm ci"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && npm run build"
    [[ $DRY_RUN -eq 1 ]] || [[ -d "$RELEASE_DIR/isales-web/dist" ]] \
        || die "expected $RELEASE_DIR/isales-web/dist after build"
}

# ---------- step 5: DingRTC SDK + binding ----------

step_dingrtc_sdk() {
    log_info "step 5/8a: install DingRTC Linux SDK at /opt/isales/vendor/DingRTC_Linux_SDK_*/"
    # DingRTC SDK install is OS-level (does not require /opt/isales/current
    # to exist). install-dingrtc-sdk.sh is idempotent — re-running on a
    # box that already has the same VERSION is a no-op.
    run sudo -u isales bash "$SCRIPT_DIR/install-dingrtc-sdk.sh"

    log_info "step 5/8b: build dingrtc_pywrap pybind11 binding into $RELEASE_DIR venv"
    # Build the project-internal pybind11 binding against the just-
    # installed vendor SDK, targeting the release's shared venv. The
    # script reads VIRTUAL_ENV to pick the right Python; export it so
    # the build resolves the release's interpreter.
    local engine_repo=$RELEASE_DIR/isales-engine
    local build_script=$engine_repo/deploy/cloud/scripts/build-dingrtc-binding.sh
    [[ -x "$build_script" ]] || die "binding build script missing: $build_script"
    local sdk_dir
    sdk_dir=$(find /opt/isales/vendor -maxdepth 1 -type d -name 'DingRTC_Linux_SDK_*' | sort | head -n1)
    [[ -n "$sdk_dir" ]] || die "DingRTC SDK not found under /opt/isales/vendor/ — step 5/8a should have installed it"
    run sudo -u isales -E env VIRTUAL_ENV="$RELEASE_DIR/venv" \
        ISALES_DINGRTC_LINUX_SDK_PATH="$sdk_dir" \
        bash "$build_script"
}

# ---------- step 6: systemd units ----------

CLOUD_UNITS=(isales-api isales-engine isales-scheduler isales-worker)

step_systemd() {
    log_info "step 6/8: sync systemd units to /etc/systemd/system/"
    local unit src dst
    for unit in "${CLOUD_UNITS[@]}"; do
        src=$META_REPO_DIR/deploy/cloud/systemd/$unit.service
        dst=/etc/systemd/system/$unit.service
        [[ -f "$src" ]] || die "missing unit source: $src"
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would install $src -> $dst"
            continue
        fi
        install -m 0644 -o root -g root "$src" "$dst"
        log_info "installed $unit.service"
    done
    run systemctl daemon-reload
}

# ---------- step 7: nginx ----------

step_nginx() {
    log_info "step 7/8: sync nginx config"
    local src=$META_REPO_DIR/deploy/cloud/nginx/isales.conf
    local dst=/etc/nginx/sites-available/isales
    [[ -f "$src" ]] || die "missing nginx source: $src"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $src -> $dst (rewrite __ISALES_DOMAIN__=$ISALES_DOMAIN)"
        log_dry "would link /var/www/isales-web -> /opt/isales/current/isales-web/dist"
        return 0
    fi
    sed "s|__ISALES_DOMAIN__|$ISALES_DOMAIN|g" "$src" > "$dst"
    chmod 0644 "$dst"
    chown root:root "$dst"
    ln -sfn /opt/isales/current/isales-web/dist /var/www/isales-web
    ln -sfn "$dst" /etc/nginx/sites-enabled/isales
    log_info "installed nginx config ($ISALES_DOMAIN)"
}

# ---------- step 8: env drop-ins ----------

ENV_DROPINS=(
    "isales-api.service       api"
    "isales-engine.service    engine"
    "isales-scheduler.service scheduler"
    "isales-worker.service    worker"
)

step_env_dropins() {
    log_info "step 8/8: write EnvironmentFile drop-ins"
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
        cat > "$conf" <<EOF
# Managed by deploy/cloud/scripts/install.sh. Edits will be overwritten.
[Service]
EnvironmentFile=
EnvironmentFile=/etc/isales/env/$envname.env
EOF
        chmod 0644 "$conf"
        log_info "wrote $conf"
    done
    run systemctl daemon-reload
}

# ---------- main ----------

main() {
    log_info "iSales cloud install.sh (release=$RELEASE_TS, ref=$GIT_REF, DRY_RUN=$DRY_RUN)"
    step_release_dir
    step_clone
    step_venv
    step_web
    step_dingrtc_sdk
    step_systemd
    step_nginx
    step_env_dropins
    TRAP_CLEANUP=0
    log_info "install complete: $RELEASE_DIR"
    log_info "next:"
    log_info "  sudo -u isales bash deploy/linux/scripts/migrate.sh"
    log_info "  sudo bash $0 --activate $RELEASE_TS"
}

main "$@"
