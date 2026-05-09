#!/usr/bin/env bash
#
# install.sh — build a new release under /opt/isales/releases/<ts>/ on macOS.
#
# Does NOT touch the `current` symlink — that is deploy.sh's job.
#
# Usage:
#     sudo bash deploy/macos/scripts/install.sh v0.1.0
#     sudo bash deploy/macos/scripts/install.sh main --dry-run
#
# Environment overrides:
#     ISALES_GIT_BASE   default: https://github.com/tommax-bai
#     ISALES_REPOS      space-separated repo list (default: 7 standard repos)
#
# Steps:
#   1. Resolve target release dir /opt/isales/releases/<ts>/
#   2. Clone or update each of the 7 repos into the release dir
#   3. Create a shared venv via $BREW_PREFIX/opt/python@3.12 + pip install
#      isales-common + 5 services (isales-telephony installs `[macos]` extras)
#   4. Build isales-web (npm ci && npm run build → dist/)
#   5. Sync 6 launchd plists to /Library/LaunchDaemons/, inlining
#      /etc/isales/env/<svc>.env into <key>EnvironmentVariables</key>
#   6. Sync nginx config to $BREW_PREFIX/etc/nginx/servers/isales.conf and
#      symlink isales-web/dist into $BREW_PREFIX/var/www/isales-web

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- args ----------

mapfile -t REST < <(parse_common_flags "$@")

GIT_REF=""
for arg in "${REST[@]+"${REST[@]}"}"; do
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

require_macos
require_root

GIT_BASE=${ISALES_GIT_BASE:-https://github.com/tommax-bai}
# shellcheck disable=SC2206
REPOS=(${ISALES_REPOS:-isales-common isales-api isales-engine isales-scheduler isales-worker isales-telephony isales-web})

RELEASE_TS=$(date +%Y%m%d-%H%M%S)
RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
VENV_DIR=$RELEASE_DIR/venv
PYTHON_BIN=$BREW_PREFIX/opt/python@3.12/bin/python3.12
NPM_BIN=$BREW_PREFIX/opt/node@20/bin/npm

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
        log_dry "(as $ISALES_USER) $*"
    else
        log_info "(as $ISALES_USER) $*"
        sudo -u "$ISALES_USER" -H bash -c "$*"
    fi
}

# ---------- step 1: release dir ----------

step_release_dir() {
    log_info "step 1/6: prepare release dir $RELEASE_DIR"
    run install -d -m 0755 -o "$ISALES_USER" -g "$ISALES_GROUP" "$RELEASE_DIR"
    TRAP_CLEANUP=1
}

# ---------- step 2: clone/update repos ----------

step_clone() {
    log_info "step 2/6: clone/update repos at ref=$GIT_REF"
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
    log_info "step 3/6: create venv + pip install"
    [[ -x "$PYTHON_BIN" ]] || die "missing $PYTHON_BIN — run provision.sh first"
    run_as_isales "'$PYTHON_BIN' -m venv '$VENV_DIR'"
    run_as_isales "'$VENV_DIR/bin/pip' install --upgrade pip wheel"
    run_as_isales "'$VENV_DIR/bin/pip' install -e '$RELEASE_DIR/isales-common'"
    local svc spec
    for svc in isales-api isales-engine isales-scheduler isales-worker isales-telephony; do
        # Pin macOS extras for isales-telephony only (sounddevice / pyserial); others install plain.
        if [[ "$svc" == "isales-telephony" ]]; then
            spec="-e '${RELEASE_DIR}/${svc}[macos]'"
        else
            spec="-e '${RELEASE_DIR}/${svc}'"
        fi
        run_as_isales "'$VENV_DIR/bin/pip' install $spec"
    done
}

# ---------- step 4: web build ----------

step_web() {
    log_info "step 4/6: build isales-web"
    [[ -x "$NPM_BIN" ]] || die "missing $NPM_BIN — run provision.sh first"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && '$NPM_BIN' ci"
    run_as_isales "cd '$RELEASE_DIR/isales-web' && '$NPM_BIN' run build"
    [[ $DRY_RUN -eq 1 ]] || [[ -d "$RELEASE_DIR/isales-web/dist" ]] \
        || die "expected $RELEASE_DIR/isales-web/dist after build"
}

# ---------- step 5: launchd plists with inlined env ----------

# (plist-basename env-file-basename)
LAUNCHD_PLISTS=(
    "com.isales.api.plist              api"
    "com.isales.engine.plist           engine"
    "com.isales.scheduler.plist        scheduler"
    "com.isales.worker.plist           worker"
    "com.isales.telephony-api.plist    telephony-api"
    "com.isales.modem-controller.plist modem-controller"
)

# Use the cached system Python (pre-installed on macOS) for plistlib so we
# don't depend on the brew Python being on PATH for root.
SYS_PYTHON3=/usr/bin/python3

# render_plist <src-plist> <env-file> <dst-plist>
# Reads <src-plist>, parses <env-file> (KEY=VALUE lines, comments / blanks
# ignored, double-quoted values stripped of quotes), inserts/replaces the
# EnvironmentVariables dict, writes XML plist to <dst-plist>.
render_plist() {
    local src=$1 envfile=$2 dst=$3
    "$SYS_PYTHON3" - "$src" "$envfile" "$dst" <<'PYEOF'
import plistlib
import re
import sys

src, envfile, dst = sys.argv[1], sys.argv[2], sys.argv[3]

env = {}
with open(envfile, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        env[key] = value

with open(src, "rb") as fh:
    pl = plistlib.load(fh)
pl["EnvironmentVariables"] = env
with open(dst, "wb") as fh:
    plistlib.dump(pl, fh)
PYEOF
}

step_launchd() {
    log_info "step 5/6: install launchd plists with inlined env"
    local entry plist envname src envfile dst
    for entry in "${LAUNCHD_PLISTS[@]}"; do
        plist=${entry%% *}
        envname=${entry##* }
        src=$META_REPO_DIR/deploy/macos/plist/$plist
        envfile=/etc/isales/env/$envname.env
        dst=/Library/LaunchDaemons/$plist

        [[ -f "$src" ]] || die "missing plist source: $src"
        [[ -f "$envfile" ]] || die "missing env file: $envfile (run provision.sh + edit secrets first)"

        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would render $src + inline $envfile -> $dst (plutil -lint)"
            continue
        fi

        render_plist "$src" "$envfile" "$dst"
        plutil -lint "$dst" >/dev/null \
            || die "rendered plist failed plutil -lint: $dst"
        chmod 0644 "$dst"
        chown root:wheel "$dst"
        log_info "installed $dst"
    done

    # Daily backup launchd job — no env inlining (script reads /etc/isales/env
    # directly at run time, like the Linux cron version).
    local backup_src=$META_REPO_DIR/deploy/macos/launchd-jobs/com.isales.backup.plist
    local backup_dst=/Library/LaunchDaemons/com.isales.backup.plist
    if [[ ! -f "$backup_src" ]]; then
        log_warn "missing $backup_src — skipping backup plist install"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $backup_src -> $backup_dst + launchctl bootstrap system"
        return 0
    fi
    install -m 0644 -o root -g wheel "$backup_src" "$backup_dst"
    plutil -lint "$backup_dst" >/dev/null \
        || die "backup plist failed plutil -lint: $backup_dst"
    # Bootstrap idempotently: bootout if already loaded so the new plist takes
    # effect (StartCalendarInterval, ProgramArguments may have changed).
    if launchctl print system/com.isales.backup >/dev/null 2>&1; then
        launchctl bootout system "$backup_dst" 2>/dev/null || true
    fi
    launchctl bootstrap system "$backup_dst"
    log_info "installed + bootstrapped $backup_dst"
}

# ---------- step 6: nginx ----------

step_nginx() {
    log_info "step 6/6: sync nginx config"
    local src=$RELEASE_DIR/isales-web/deploy/nginx.conf
    local dst=$BREW_PREFIX/etc/nginx/servers/isales.conf
    [[ -f "$src" ]] || die "missing nginx source: $src"

    install -d -m 0755 "$BREW_PREFIX/etc/nginx/servers"
    install -d -m 0755 "$BREW_PREFIX/var/www"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $src -> $dst + symlink $BREW_PREFIX/var/www/isales-web"
        return 0
    fi

    install -m 0644 -o root -g wheel "$src" "$dst"
    ln -sfn /opt/isales/current/isales-web/dist "$BREW_PREFIX/var/www/isales-web"
    log_info "installed nginx config + dist symlink"
}

# ---------- main ----------

main() {
    log_info "iSales install.sh (macOS) starting (release=$RELEASE_TS, ref=$GIT_REF, DRY_RUN=$DRY_RUN)"
    step_release_dir
    step_clone
    step_venv
    step_web
    step_launchd
    step_nginx
    TRAP_CLEANUP=0   # success; do not clean
    log_info "install complete: $RELEASE_DIR"
    log_info "next: bash deploy/macos/scripts/migrate.sh && bash deploy/macos/scripts/deploy.sh $RELEASE_TS"
}

main "$@"
