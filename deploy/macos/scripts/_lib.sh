# shellcheck shell=bash
# macOS-specific deploy helpers. Sources deploy/common/_lib.sh and adds
# macOS-only constants (Homebrew prefix, brew package list, etc).
#
# Usage in a script:
#     # shellcheck source=./_lib.sh
#     source "$(dirname "$0")/_lib.sh"

set -euo pipefail

ISALES_PLATFORM=macos

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/_lib.sh
source "$_LIB_DIR/../../common/_lib.sh"

# ---------- Homebrew prefix (Apple Silicon) ----------
# Apple Silicon brew installs to /opt/homebrew. We do NOT support Intel Mac
# (Decision: design.md Goals/Non-Goals); fail fast if /opt/homebrew is absent.
# shellcheck disable=SC2034  # consumed by callers
BREW_PREFIX=/opt/homebrew

# ---------- macOS brew package list ----------
# postgresql@15 + redis + nginx + python@3.12 + node@20 cover the full stack;
# pkg-config + git are required for pip installs of native deps.
# shellcheck disable=SC2034
MACOS_BREW_PACKAGES=(
    postgresql@15
    redis
    nginx
    python@3.12
    node@20
    pkg-config
    git
)

# ---------- macOS env template dir ----------
# shellcheck disable=SC2034
ISALES_ENV_TEMPLATE_DIR="$_LIB_DIR/../../env"

# ---------- macOS service account ----------
# `_isales` follows Apple's convention of leading-underscore for system
# accounts; UID range 200-499 is reserved for hidden system users.
# shellcheck disable=SC2034
ISALES_USER=_isales
# shellcheck disable=SC2034
ISALES_GROUP=_isales
# shellcheck disable=SC2034
ISALES_USER_UID=298
# shellcheck disable=SC2034
ISALES_USER_GID=298

# ---------- macOS-only sanity check ----------

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || die "this script must run on macOS (Darwin)"
    local arch
    arch=$(uname -m)
    [[ "$arch" == "arm64" ]] || die "Apple Silicon required (uname -m: $arch)"
    local ver major
    ver=$(sw_vers -productVersion)
    major=${ver%%.*}
    [[ "$major" -ge 14 ]] || die "macOS 14+ (Sonoma) required (current: $ver)"
}
