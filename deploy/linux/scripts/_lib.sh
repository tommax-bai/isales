# shellcheck shell=bash
# Linux-specific deploy helpers. Sources deploy/common/_lib.sh and adds
# Linux-only constants (apt package list etc).
#
# Usage in a script:
#     # shellcheck source=./_lib.sh
#     source "$(dirname "$0")/_lib.sh"

set -euo pipefail

ISALES_PLATFORM=linux

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/_lib.sh
source "$_LIB_DIR/../../common/_lib.sh"

# ---------- Linux apt package list ----------
# shellcheck disable=SC2034  # consumed by provision.sh via ${LINUX_APT_PACKAGES[@]}
LINUX_APT_PACKAGES=(
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

# ---------- Linux env template dir ----------
# Used by bootstrap_env_file calls in provision.sh.
# shellcheck disable=SC2034  # exported for callers
ISALES_ENV_TEMPLATE_DIR="$_LIB_DIR/../../env"

# Deprecation banner: warn callers invoked via the legacy deploy/scripts/
# symlink. Check the parent script's original argv[0] ($0) — bash leaves it
# pointing to the user-supplied path even when the symlink target's pwd was
# canonicalised by the script's `cd "$(dirname "$0")"` step.
if [[ "${0:-}" == */deploy/scripts/* ]]; then
    log_warn "deploy/scripts/ is deprecated; use deploy/linux/scripts/ instead (one-release grace period)"
fi
