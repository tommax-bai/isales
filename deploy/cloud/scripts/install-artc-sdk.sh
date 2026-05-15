#!/usr/bin/env bash
#
# install-artc-sdk.sh — fetch the ARTC SDK for Linux Python from OSS and
# extract it under the active release's vendor/ directory.
#
# Source of truth for the layout:
#   /opt/isales/current/vendor/aliyun-artc-linux-python/
#     lib/        *.so shared libraries (LD_LIBRARY_PATH target)
#     python/     python wrapper modules (PYTHONPATH target)
#     LICENSE
#     VERSION     plain text version tag, e.g. "7.10.2"
#
# Usage:
#     sudo -u isales bash deploy/cloud/scripts/install-artc-sdk.sh
#     sudo -u isales bash deploy/cloud/scripts/install-artc-sdk.sh --version 7.10.2
#     sudo -u isales bash deploy/cloud/scripts/install-artc-sdk.sh --tarball file:///tmp/sdk.tgz
#
# Environment:
#     ISALES_ARTC_SDK_OSS_URL   default: oss://isales-prod/vendor/artc/linux/aliyun-artc-linux-python-${VERSION}.tgz
#     ISALES_ARTC_SDK_VERSION   default: 7.10.2 (matches ~/codes/vendor/AliRTCSDK_Linux-7.10.2/)
#     OSSUTIL_BIN               default: /usr/local/bin/ossutil
#
# Idempotent: re-running with the same VERSION is a no-op (checks vendor/VERSION).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# deploy/cloud/scripts -> repo root
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../linux/scripts/_lib.sh
source "$META_REPO_DIR/deploy/linux/scripts/_lib.sh"

# ---------- args ----------

parse_common_flags "$@"

VERSION=${ISALES_ARTC_SDK_VERSION:-7.10.2}
TARBALL_OVERRIDE=""

for arg in "${REST[@]:-}"; do
    case "$arg" in
        --version) shift; VERSION=$1 ;;
        --version=*) VERSION=${arg#--version=} ;;
        --tarball) shift; TARBALL_OVERRIDE=$1 ;;
        --tarball=*) TARBALL_OVERRIDE=${arg#--tarball=} ;;
        --help|-h) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
    esac
done

OSS_URL=${ISALES_ARTC_SDK_OSS_URL:-oss://isales-prod/vendor/artc/linux/aliyun-artc-linux-python-${VERSION}.tgz}
[[ -n "$TARBALL_OVERRIDE" ]] && OSS_URL=$TARBALL_OVERRIDE

CURRENT=/opt/isales/current
[[ -L "$CURRENT" ]] || die "$CURRENT is not a symlink — run deploy/cloud/scripts/install.sh first"
RELEASE_DIR=$(readlink -f "$CURRENT")
VENDOR_DIR=$RELEASE_DIR/vendor/aliyun-artc-linux-python

# ---------- idempotence ----------

if [[ -f "$VENDOR_DIR/VERSION" ]] && [[ "$(cat "$VENDOR_DIR/VERSION")" == "$VERSION" ]]; then
    log_info "ARTC SDK $VERSION already installed at $VENDOR_DIR; nothing to do"
    exit 0
fi

# ---------- fetch ----------

TMPDIR_FOR_SDK=$(mktemp -d /tmp/artc-sdk.XXXXXX)
trap 'rm -rf "$TMPDIR_FOR_SDK"' EXIT
TARBALL=$TMPDIR_FOR_SDK/sdk.tgz

case "$OSS_URL" in
    oss://*)
        OSSUTIL=${OSSUTIL_BIN:-/usr/local/bin/ossutil}
        [[ -x "$OSSUTIL" ]] || die "ossutil not found at $OSSUTIL; install via 'sudo curl -L https://gosspublic.alicdn.com/ossutil/install.sh | bash'"
        log_info "downloading $OSS_URL via ossutil"
        run "$OSSUTIL" cp "$OSS_URL" "$TARBALL"
        ;;
    file://*)
        log_info "copying $OSS_URL"
        run cp "${OSS_URL#file://}" "$TARBALL"
        ;;
    http://*|https://*)
        log_info "fetching $OSS_URL via curl"
        run curl -fsSL -o "$TARBALL" "$OSS_URL"
        ;;
    *)
        die "unsupported url scheme: $OSS_URL"
        ;;
esac

# ---------- extract ----------

log_info "extracting to $VENDOR_DIR"
run install -d -m 0755 -o isales -g isales "$VENDOR_DIR"
# Tarball top-level layout is convention; if vendor packaging differs, adjust here.
run tar -xzf "$TARBALL" -C "$VENDOR_DIR" --strip-components=1
echo "$VERSION" > "$VENDOR_DIR/VERSION"
chown -R isales:isales "$VENDOR_DIR"

# ---------- sanity ----------

[[ -d "$VENDOR_DIR/lib" ]]    || die "extracted tarball missing lib/  ($VENDOR_DIR/lib)"
[[ -d "$VENDOR_DIR/python" ]] || die "extracted tarball missing python/  ($VENDOR_DIR/python)"

log_info "ARTC SDK $VERSION installed at $VENDOR_DIR"
log_info "engine.env points:"
log_info "  LD_LIBRARY_PATH=$VENDOR_DIR/lib"
log_info "  PYTHONPATH=$VENDOR_DIR/python"
log_info "restart engine for changes to take effect:"
log_info "  sudo systemctl restart isales-engine"
