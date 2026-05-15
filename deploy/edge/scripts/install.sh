#!/usr/bin/env bash
#
# install.sh — edge-side install for A2 cloud-edge split topology.
# Runs on macOS 14+ as the LOGIN USER (not root). Targets:
#
#   /opt/isales/releases/<ts>/                       cloned repos + venv
#   /opt/isales/current  ->  releases/<ts>           atomic symlink
#   ~/Library/LaunchAgents/com.isales.telephony.plist  per-user launchd
#   ~/Library/Application Support/isales/            state (sqlite, recordings)
#   ~/Library/Logs/isales/                            stdout/stderr
#   ~/.config/isales/edge.env                         user env (0600)
#
# Usage:
#     bash deploy/edge/scripts/install.sh v1.0.0
#     bash deploy/edge/scripts/install.sh main --dry-run
#     bash deploy/edge/scripts/install.sh --activate 20260515-103000
#
# Pre-requisites (one-time, by a privileged user):
#     sudo install -d -o $USER -g staff /opt/isales /opt/isales/releases
#     brew install python@3.12
#
# Env overrides:
#     ISALES_GIT_BASE   default: https://github.com/tommax-bai
#     ISALES_REPOS      default: isales-common isales-telephony
#
# Steps:
#   1. Prepare release dir
#   2. Clone isales-common + isales-telephony
#   3. Create venv, pip install -e common + telephony (+ scipy for resampler)
#   4. Sync LaunchAgent plist (rewrite __HOME__)
#   5. Bootstrap state dirs + log dirs + env file (if missing)
#   6. (--activate) swap /opt/isales/current symlink + launchctl kickstart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Use macOS-flavored common helpers (parse_common_flags / log_* / run).
# shellcheck source=../../macos/scripts/_lib.sh
source "$META_REPO_DIR/deploy/macos/scripts/_lib.sh"

# ---------- args ----------

parse_common_flags "$@"

GIT_REF=""
ACTIVATE_TS=""
ACTIVATE_MODE=0

for arg in "${REST[@]:-}"; do
    case "$arg" in
        --activate) shift; ACTIVATE_TS=$1; ACTIVATE_MODE=1 ;;
        --activate=*) ACTIVATE_TS=${arg#--activate=}; ACTIVATE_MODE=1 ;;
        --help|-h) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *)  GIT_REF=$arg ;;
    esac
done

CURRENT=/opt/isales/current
LAUNCH_AGENT_DIR=$HOME/Library/LaunchAgents
LAUNCH_AGENT_PLIST=$LAUNCH_AGENT_DIR/com.isales.telephony.plist
LABEL=com.isales.telephony

if [[ $EUID -eq 0 ]]; then
    die "do not run as root; install.sh is a per-user installer (uses LaunchAgent)"
fi

# ---------- activate-only ----------

activate_release() {
    local ts=$1
    local target=/opt/isales/releases/$ts
    [[ -d "$target" ]] || die "release does not exist: $target"
    [[ -x "$target/venv/bin/python" ]] || die "venv missing in $target (incomplete release)"

    local prev
    prev=$(readlink "$CURRENT" 2>/dev/null || echo "<none>")
    log_info "activate: $prev -> $target"
    run ln -sfn "$target" "$CURRENT"

    if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
        # kickstart restarts the agent in-place; -k forces termination of an
        # existing process before restarting.
        run launchctl kickstart -k "gui/$UID/$LABEL"
    else
        log_warn "LaunchAgent plist not installed yet; skipping kickstart"
        log_info "to load:"
        log_info "  launchctl bootstrap gui/\$UID $LAUNCH_AGENT_PLIST"
    fi
    log_info "activation complete"
}

if [[ $ACTIVATE_MODE -eq 1 ]]; then
    [[ -n "$ACTIVATE_TS" ]] || die "missing --activate <release-ts>"
    activate_release "$ACTIVATE_TS"
    exit 0
fi

# ---------- install ----------

[[ -n "$GIT_REF" ]] || die "missing <git-ref> arg (e.g. v1.0.0). Use --help."

GIT_BASE=${ISALES_GIT_BASE:-https://github.com/tommax-bai}
# shellcheck disable=SC2206
REPOS=(${ISALES_REPOS:-isales-common isales-telephony})

[[ -d /opt/isales/releases ]] \
    || die "/opt/isales/releases missing — run: sudo install -d -o \$USER -g staff /opt/isales /opt/isales/releases"
[[ -w /opt/isales/releases ]] \
    || die "/opt/isales/releases not writable by $USER — fix ownership first"

RELEASE_TS=$(date +%Y%m%d-%H%M%S)
RELEASE_DIR=/opt/isales/releases/$RELEASE_TS
VENV_DIR=$RELEASE_DIR/venv

TRAP_CLEANUP=0
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]] && [[ $TRAP_CLEANUP -eq 1 ]] && [[ -d "$RELEASE_DIR" ]]; then
        log_err "install failed; cleaning up: $RELEASE_DIR"
        rm -rf "$RELEASE_DIR"
    fi
}
trap on_exit EXIT

# ---------- step 1: release dir ----------

step_release_dir() {
    log_info "step 1/5: prepare release dir $RELEASE_DIR"
    run mkdir -p "$RELEASE_DIR"
    TRAP_CLEANUP=1
}

# ---------- step 2: clone ----------

step_clone() {
    log_info "step 2/5: clone repos at ref=$GIT_REF"
    local repo url dst
    for repo in "${REPOS[@]}"; do
        url=$GIT_BASE/$repo.git
        dst=$RELEASE_DIR/$repo
        run git clone --depth 50 "$url" "$dst"
        run git -C "$dst" fetch --tags origin
        run git -C "$dst" checkout "$GIT_REF"
    done
}

# ---------- step 3: venv ----------

step_venv() {
    log_info "step 3/5: create venv + pip install"
    run python3.12 -m venv "$VENV_DIR"
    run "$VENV_DIR/bin/pip" install --upgrade pip wheel
    run "$VENV_DIR/bin/pip" install -e "$RELEASE_DIR/isales-common"
    run "$VENV_DIR/bin/pip" install -e "$RELEASE_DIR/isales-telephony"
    # scipy needed for audio_bridge/resampler (polyphase FIR; see PR #2 telephony).
    # In future, isales-telephony pyproject should pin this; until then install
    # explicitly to keep edge installs reproducible.
    run "$VENV_DIR/bin/pip" install "scipy>=1.11"
}

# ---------- step 4: LaunchAgent ----------

step_launchagent() {
    log_info "step 4/5: sync LaunchAgent plist"
    local src=$META_REPO_DIR/deploy/edge/launchd/com.isales.telephony.plist
    [[ -f "$src" ]] || die "missing $src"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_dry "would write $LAUNCH_AGENT_PLIST (rewrite __HOME__=$HOME)"
        return 0
    fi
    mkdir -p "$LAUNCH_AGENT_DIR"
    sed "s|__HOME__|$HOME|g" "$src" > "$LAUNCH_AGENT_PLIST"
    chmod 0644 "$LAUNCH_AGENT_PLIST"
    log_info "wrote $LAUNCH_AGENT_PLIST"
}

# ---------- step 5: state + env bootstrap ----------

step_bootstrap_state() {
    log_info "step 5/5: bootstrap state + log + env dirs"
    run mkdir -p "$HOME/Library/Application Support/isales/sqlite"
    run mkdir -p "$HOME/Library/Application Support/isales/recordings"
    run mkdir -p "$HOME/Library/Application Support/isales/vendor"
    run mkdir -p "$HOME/Library/Logs/isales"
    run mkdir -p "$HOME/.config/isales"

    local env_file=$HOME/.config/isales/edge.env
    if [[ ! -f "$env_file" ]]; then
        log_info "writing initial env template to $env_file (edit before activate!)"
        if [[ $DRY_RUN -eq 1 ]]; then
            log_dry "would copy $META_REPO_DIR/deploy/edge/env/edge.env.example -> $env_file"
        else
            cp "$META_REPO_DIR/deploy/edge/env/edge.env.example" "$env_file"
            chmod 0600 "$env_file"
        fi
    else
        log_info "$env_file already exists; not overwriting"
    fi
}

# ---------- main ----------

main() {
    log_info "iSales edge install.sh (release=$RELEASE_TS, ref=$GIT_REF, DRY_RUN=$DRY_RUN)"
    step_release_dir
    step_clone
    step_venv
    step_launchagent
    step_bootstrap_state
    TRAP_CLEANUP=0
    log_info "install complete: $RELEASE_DIR"
    log_info "next:"
    log_info "  $EDITOR $HOME/.config/isales/edge.env   # fill in device-id / token / cloud URL"
    log_info "  bash $0 --activate $RELEASE_TS          # swap current + kickstart"
    log_info "  launchctl bootstrap gui/\$UID $LAUNCH_AGENT_PLIST   # first-time only"
}

main "$@"
