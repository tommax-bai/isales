#!/usr/bin/env bash
# macOS ships /bin/bash 3.2 (GPL3-frozen). All scripts here use bash 4+
# features (mapfile, "${arr[@]+...}", etc.). Re-exec under brew bash if
# the current shell is too old.
if [[ ${BASH_VERSINFO[0]:-3} -lt 4 ]]; then
    exec /opt/homebrew/bin/bash "$0" "$@"
fi
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
#      /etc/isales/env/<svc>.env into <key>EnvironmentVariables</key>.
#      Also installs com.isales.bootstrap-runtime.plist (recreates
#      /var/run/isales after each boot) and com.isales.backup.plist
#      (daily PG+Redis dump). Backup scripts are sourced from
#      /opt/isales/current/deploy/, populated in step_release_dir.
#   6. Sync nginx config to $BREW_PREFIX/etc/nginx/servers/isales.conf and
#      symlink isales-web/dist into $BREW_PREFIX/var/www/isales-web

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---------- args ----------

parse_common_flags "$@"

GIT_REF=""
SKIP_CLONE=0
for arg in "${REST[@]+"${REST[@]}"}"; do
    case "$arg" in
        --help|-h)
            sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --skip-clone) SKIP_CLONE=1 ;;
        --release-dir=*) RELEASE_DIR_OVERRIDE=${arg#*=} ;;
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
if [[ -n "${RELEASE_DIR_OVERRIDE:-}" ]]; then
    RELEASE_DIR=$RELEASE_DIR_OVERRIDE
    RELEASE_TS=$(basename "$RELEASE_DIR")
else
    RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
fi
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
    # cd to /opt/isales first: when invoked from a sudo/osascript admin
    # context, the cwd inherited by the sub-shell may be unreadable to
    # _isales (e.g. /var/root, the script's launch dir), causing git's
    # getcwd() probe to fail before it even tries to clone.
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "(as $ISALES_USER) $*"
    else
        log_info "(as $ISALES_USER) $*"
        sudo -u "$ISALES_USER" -H bash -c "cd /opt/isales && $*"
    fi
}

# ---------- step 1: release dir ----------

step_release_dir() {
    log_info "step 1/6: prepare release dir $RELEASE_DIR + sync deploy/"
    if [[ -d "$RELEASE_DIR" ]] && [[ $SKIP_CLONE -eq 1 ]]; then
        log_info "release dir already exists; SKIP_CLONE set, reusing"
    else
        run install -d -m 0755 -o "$ISALES_USER" -g "$ISALES_GROUP" "$RELEASE_DIR"
    fi
    TRAP_CLEANUP=1

    # The backup launchd job runs scripts from /opt/isales/current/deploy/…
    # (via the `current` symlink that deploy.sh flips). install.sh is the only
    # path that materialises the meta-repo `deploy/` subtree inside a release,
    # because git clone in step_clone only pulls the 7 service repos.
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would sync $META_REPO_DIR/deploy/ -> $RELEASE_DIR/deploy/"
    else
        log_info "syncing meta-repo deploy/ into $RELEASE_DIR/deploy/"
        rm -rf "$RELEASE_DIR/deploy"
        # -L so we materialise the deploy/scripts symlink (Linux compat) rather
        # than carry a broken link into the release.
        cp -RL "$META_REPO_DIR/deploy" "$RELEASE_DIR/deploy"
        chown -R "$ISALES_USER:$ISALES_GROUP" "$RELEASE_DIR/deploy"
    fi
}

# ---------- step 2: clone/update repos ----------

step_clone() {
    if [[ $SKIP_CLONE -eq 1 ]]; then
        log_info "step 2/6: skipped (--skip-clone). Verifying pre-populated repos in $RELEASE_DIR"
        local repo
        for repo in "${REPOS[@]}"; do
            [[ -d "$RELEASE_DIR/$repo" ]] \
                || die "missing pre-populated repo: $RELEASE_DIR/$repo (--skip-clone requires you to copy all 7 repos in beforehand)"
        done
        return 0
    fi
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

    # Boot-time bootstrap plist: recreates /var/run/isales (cleared on reboot
    # because /var/run is tmpfs on modern macOS) before any service plist
    # tries to bind its unix domain socket. Idempotent bootout/bootstrap so
    # path or args changes take effect on re-install.
    local boot_src=$META_REPO_DIR/deploy/macos/launchd-jobs/com.isales.bootstrap-runtime.plist
    local boot_dst=/Library/LaunchDaemons/com.isales.bootstrap-runtime.plist
    if [[ ! -f "$boot_src" ]]; then
        die "missing bootstrap-runtime plist source: $boot_src"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $boot_src -> $boot_dst + launchctl bootstrap system"
    else
        install -m 0644 -o root -g wheel "$boot_src" "$boot_dst"
        plutil -lint "$boot_dst" >/dev/null \
            || die "bootstrap-runtime plist failed plutil -lint: $boot_dst"
        if launchctl print system/com.isales.bootstrap-runtime >/dev/null 2>&1; then
            launchctl bootout system "$boot_dst" 2>/dev/null || true
        fi
        launchctl bootstrap system "$boot_dst"
        # Wait briefly for the one-shot job to create /var/run/isales before
        # service plists attempt to bind their sockets. Polling is cheap; the
        # bootstrap job exits in well under a second.
        local _i
        for _i in 1 2 3 4 5; do
            [[ -d /var/run/isales ]] && break
            sleep 0.2
        done
        [[ -d /var/run/isales ]] \
            || log_warn "/var/run/isales still missing after bootstrap-runtime; modem-controller may flap on first start"
        log_info "installed + bootstrapped $boot_dst"
    fi

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

    # Skip the file-existence assertion under DRY_RUN — the release dir
    # hasn't actually been created yet, so $src is guaranteed to be missing.
    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would install $src -> $dst + symlink $BREW_PREFIX/var/www/isales-web"
        return 0
    fi

    [[ -f "$src" ]] || die "missing nginx source: $src"
    install -d -m 0755 "$BREW_PREFIX/etc/nginx/servers"
    install -d -m 0755 "$BREW_PREFIX/var/www"

    # The isales-web repo's nginx.conf template targets Linux paths
    # (`listen 80; root /var/www/isales-web;`). On macOS brew the docroot is
    # `$BREW_PREFIX/var/www/...` and binding to port 80 needs root, so brew
    # nginx running as the user account has to use 8080. Rewrite both on the
    # fly so the source template stays Linux-canonical.
    sed -E \
        -e 's|^([[:space:]]*)listen 80;|\1listen 8080 default_server;|' \
        -e "s|^([[:space:]]*root[[:space:]]+)/var/www/|\\1$BREW_PREFIX/var/www/|" \
        "$src" > "${dst}.new"
    install -m 0644 -o root -g wheel "${dst}.new" "$dst"
    rm -f "${dst}.new"

    # Brew's default nginx.conf ships an example `server { listen 8080; }`
    # block. Comment it out (idempotent) so our default_server isales.conf
    # owns 8080 cleanly.
    if grep -qE '^[[:space:]]+listen[[:space:]]+8080;' "$BREW_PREFIX/etc/nginx/nginx.conf"; then
        # Remove the entire default server block (its 4-space indent makes it
        # easy to identify; we replace `    server { ... }` with `    # ...`).
        # If already commented, this is a no-op.
        python3 - "$BREW_PREFIX/etc/nginx/nginx.conf" <<'PYDEFAULT'
import re, sys
p = sys.argv[1]
src = open(p).read()
sentinel = "# disabled by iSales install.sh: conflicts with isales.conf default_server"
if sentinel in src:
    sys.exit(0)
# Match the first `    server {` block in nginx.conf (4-space indent), with
# nested braces. Naive brace matching since nginx config is well-formed.
m = re.search(r'^[ ]{4}server[ ]*\{', src, re.MULTILINE)
if not m:
    sys.exit(0)
start = m.start()
i = m.end() - 1  # at the `{`
depth = 0
while i < len(src):
    if src[i] == '{':
        depth += 1
    elif src[i] == '}':
        depth -= 1
        if depth == 0:
            i += 1
            break
    i += 1
end = i
block = src[start:end]
commented = "    " + sentinel + "\n" + "\n".join(("    # " + l[4:]) if l.startswith("    ") else ("    # " + l) for l in block.splitlines())
open(p, 'w').write(src[:start] + commented + src[end:])
PYDEFAULT
    fi
    # Ensure ownership of brew nginx logs/run is the brew user (sudo runs may
    # have created files as root, breaking later starts).
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER:admin" "$BREW_PREFIX/var/log/nginx" "$BREW_PREFIX/var/run" 2>/dev/null || true
    fi

    # The rewritten config has already been installed above. Just create the
    # docroot symlink and we're done.
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
