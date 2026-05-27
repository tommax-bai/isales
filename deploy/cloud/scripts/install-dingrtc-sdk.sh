#!/usr/bin/env bash
#
# install-dingrtc-sdk.sh — fetch the DingRTC Linux C++ SDK from OSS (or
# direct vendor URL) and extract it under the OS-level vendor/ tree.
#
# Source of truth for the layout (matches deploy/cloud/STATE.md §
# "DingRTC SDK vendor"):
#
#   /opt/isales/vendor/DingRTC_Linux_SDK_3_9_0/
#     api/                         # C++ headers (#include path)
#     lib/x86_64/libDingRTC.so     # main SDK shared library (+ deps)
#     lib/x86_64/*.so              # vendor-shipped sibling libs
#     samples/, docs/              # ignored at runtime
#     VERSION                      # plain-text version tag, e.g. "3.9.0"
#
# The vendor SDK is **OS-level**, not per-release, because DingRTC's
# pure C++ surface plus our project-internal pybind11 binding
# (`isales-engine/deploy/cloud/pybind/dingrtc_pywrap/`) means the .so
# does not depend on a release-time Python ABI. The binding itself is
# built by `deploy/cloud/scripts/build-dingrtc-binding.sh` and lives in
# the active venv. install-dingrtc-sdk.sh is therefore safe to run
# **once per ECS box**, not once per release.
#
# Migration note (2026-05-27): replaces install-artc-sdk.sh, which
# pulled the now-deprecated ApsaraVideo Live ARTC SDK
# (AliRTCSDK_Linux-7.10.2 / aliyun-artc-linux-python). That SDK is a
# different product line (cross-product token mismatch with the
# DingRTC PaaS); the legacy script is deleted in the same commit.
#
# Usage:
#     sudo -u isales bash deploy/cloud/scripts/install-dingrtc-sdk.sh
#     sudo -u isales bash deploy/cloud/scripts/install-dingrtc-sdk.sh --version 3.9.0
#     sudo -u isales bash deploy/cloud/scripts/install-dingrtc-sdk.sh --archive file:///tmp/sdk.zip
#     sudo -u isales bash deploy/cloud/scripts/install-dingrtc-sdk.sh --vendor-dir /opt/custom/dingrtc
#
# Environment:
#     ISALES_DINGRTC_SDK_OSS_URL   default: oss://isales-prod/vendor/dingrtc/linux/DingRTC_Linux_SDK_3_9_0.zip
#     ISALES_DINGRTC_SDK_VERSION   default: 3.9.0
#     ISALES_DINGRTC_VENDOR_DIR    default: /opt/isales/vendor/DingRTC_Linux_SDK_${UNDERSCORED_VERSION}
#     ISALES_DINGRTC_SDK_SHA256    optional: if set, verify the downloaded archive matches
#                                  (canonical for 3.9.0:
#                                  3dc2361fbf6e9e181aba0fbdc30b488064e47f866c7d2d2ab1607c3cd53622e6)
#     OSSUTIL_BIN                  default: /usr/local/bin/ossutil
#
# Idempotent: re-running with the same VERSION is a no-op (checks
# <vendor>/VERSION).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# deploy/cloud/scripts -> repo root
META_REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../linux/scripts/_lib.sh
source "$META_REPO_DIR/deploy/linux/scripts/_lib.sh"

# ---------- args ----------

parse_common_flags "$@"

VERSION=${ISALES_DINGRTC_SDK_VERSION:-3.9.0}
ARCHIVE_OVERRIDE=""
VENDOR_DIR_OVERRIDE=""

for arg in "${REST[@]:-}"; do
    case "$arg" in
        --version) shift; VERSION=$1 ;;
        --version=*) VERSION=${arg#--version=} ;;
        --archive) shift; ARCHIVE_OVERRIDE=$1 ;;
        --archive=*) ARCHIVE_OVERRIDE=${arg#--archive=} ;;
        --vendor-dir) shift; VENDOR_DIR_OVERRIDE=$1 ;;
        --vendor-dir=*) VENDOR_DIR_OVERRIDE=${arg#--vendor-dir=} ;;
        --help|-h) sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
    esac
done

# Vendor's canonical naming uses underscores: 3.9.0 -> 3_9_0
UNDERSCORED_VERSION=${VERSION//./_}
ARCHIVE_NAME="DingRTC_Linux_SDK_${UNDERSCORED_VERSION}.zip"
OSS_URL=${ISALES_DINGRTC_SDK_OSS_URL:-oss://isales-prod/vendor/dingrtc/linux/${ARCHIVE_NAME}}
[[ -n "$ARCHIVE_OVERRIDE" ]] && OSS_URL=$ARCHIVE_OVERRIDE

VENDOR_DIR=${ISALES_DINGRTC_VENDOR_DIR:-/opt/isales/vendor/DingRTC_Linux_SDK_${UNDERSCORED_VERSION}}
[[ -n "$VENDOR_DIR_OVERRIDE" ]] && VENDOR_DIR=$VENDOR_DIR_OVERRIDE

# ---------- idempotence ----------

if [[ -f "$VENDOR_DIR/VERSION" ]] && [[ "$(cat "$VENDOR_DIR/VERSION")" == "$VERSION" ]]; then
    log_info "DingRTC SDK $VERSION already installed at $VENDOR_DIR; nothing to do"
    exit 0
fi

# ---------- fetch ----------

TMPDIR_FOR_SDK=$(mktemp -d /tmp/dingrtc-sdk.XXXXXX)
trap 'rm -rf "$TMPDIR_FOR_SDK"' EXIT
ARCHIVE=$TMPDIR_FOR_SDK/sdk.zip

case "$OSS_URL" in
    oss://*)
        OSSUTIL=${OSSUTIL_BIN:-/usr/local/bin/ossutil}
        [[ -x "$OSSUTIL" ]] || die "ossutil not found at $OSSUTIL; install via 'sudo curl -L https://gosspublic.alicdn.com/ossutil/install.sh | bash'"
        log_info "downloading $OSS_URL via ossutil"
        run "$OSSUTIL" cp "$OSS_URL" "$ARCHIVE"
        ;;
    file://*)
        log_info "copying $OSS_URL"
        run cp "${OSS_URL#file://}" "$ARCHIVE"
        ;;
    http://*|https://*)
        log_info "fetching $OSS_URL via curl"
        run curl -fsSL -o "$ARCHIVE" "$OSS_URL"
        ;;
    *)
        die "unsupported url scheme: $OSS_URL"
        ;;
esac

# ---------- optional sha256 verify ----------

if [[ -n "${ISALES_DINGRTC_SDK_SHA256:-}" ]]; then
    log_info "verifying sha256"
    ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}')
    if [[ "$ACTUAL" != "$ISALES_DINGRTC_SDK_SHA256" ]]; then
        die "sha256 mismatch: expected $ISALES_DINGRTC_SDK_SHA256, got $ACTUAL"
    fi
fi

# ---------- extract ----------

log_info "extracting to $VENDOR_DIR"
run install -d -m 0755 -o isales -g isales "$VENDOR_DIR"
# Vendor zip's top-level dir is `DingRTC_Linux_SDK_<v>/`; strip it so
# contents land directly under $VENDOR_DIR/.
TMP_EXTRACT=$TMPDIR_FOR_SDK/extract
mkdir -p "$TMP_EXTRACT"
run unzip -q "$ARCHIVE" -d "$TMP_EXTRACT"
# Find the single top-level directory and move its contents up one level.
TOP=$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -n "$TOP" ]] || die "unzipped archive has no top-level directory"
run rsync -a "$TOP"/ "$VENDOR_DIR"/
echo "$VERSION" > "$VENDOR_DIR/VERSION"
chown -R isales:isales "$VENDOR_DIR"

# ---------- sanity ----------

[[ -d "$VENDOR_DIR/api" ]]                  || die "extracted archive missing api/  ($VENDOR_DIR/api)"
[[ -f "$VENDOR_DIR/lib/x86_64/libDingRTC.so" ]] || die "extracted archive missing lib/x86_64/libDingRTC.so"

log_info "DingRTC SDK $VERSION installed at $VENDOR_DIR"
log_info "next step: build the project-internal pybind11 binding"
log_info "  sudo -u isales -E bash deploy/cloud/scripts/build-dingrtc-binding.sh"
log_info "engine.env points (set if not already):"
log_info "  ISALES_DINGRTC_LINUX_SDK_PATH=$VENDOR_DIR"
log_info "  LD_LIBRARY_PATH=$VENDOR_DIR/lib/x86_64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
log_info "restart engine for changes to take effect:"
log_info "  sudo systemctl restart isales-engine"
