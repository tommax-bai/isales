#!/usr/bin/env bash
#
# check_dingrtc_versions.sh — lint DingRTC vendor-SDK version strings across
# the three-end iSales tree (cloud / Windows edge / macOS edge).
#
# Spec: openspec/changes/engine-rtc-dingrtc-migration § 10.1.
#
# The DingRTC SDK is a proprietary vendor binary (Linux / Windows / macOS
# variants) that is NOT pip-installed; the version is therefore expressed
# in several documentation + script + comment locations and must agree
# across all of them. The single source of truth is the vendor table in
# `deploy/cloud/STATE.md § DingRTC SDK vendor` — every other mention is
# a cross-reference that this lint reads and compares.
#
# Sources (matches § 10.1 enumeration, with deploy scripts treated as one
# extra cross-check each so the script can name a concrete file):
#
#   (1) deploy/cloud/STATE.md                                   CANONICAL
#   (2) deploy/cloud/scripts/install-dingrtc-sdk.sh             default VERSION
#   (3) deploy/RUNBOOK-cloud.md                                 URL + sha256 quoted
#   (4) ../isales-engine/deploy/cloud/scripts/build-dingrtc-binding.sh
#                                                                default SDK path
#   (5) ../isales-telephony/pyproject.toml                      macos-dingrtc extras path
#   (6) ../isales-telephony/deploy/edge/windows/STATE.md        post-§ 7 target Windows
#   (7) ../isales-telephony/deploy/edge/macos/RUNBOOK.md        macOS framework
#
# Cloud-side `isales-engine/pyproject.toml` does NOT pin DingRTC anywhere
# (the vendor SDK loads via `ISALES_DINGRTC_LINUX_SDK_PATH` env at runtime,
# the pybind binding builds against the env path). Sources (2)+(4) cover
# the engine's authoritative version pins instead.
#
# Exit 0 = all sources agree; exit 1 = at least one mismatch.
# Run via `make spec-validate` (wired in § 10.2) or stand-alone.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SIBLINGS="$(cd "$META_REPO/.." && pwd)"

ENGINE_REPO="$SIBLINGS/isales-engine"
TELEPHONY_REPO="$SIBLINGS/isales-telephony"

# Canonical version table. Update here when DingRTC ships a new SDK
# release that all three platforms move to in lockstep.
EXPECTED_VERSION="3.9.0"
EXPECTED_VERSION_UNDERSCORE="${EXPECTED_VERSION//./_}"

EXPECTED_SHA256_LINUX="3dc2361fbf6e9e181aba0fbdc30b488064e47f866c7d2d2ab1607c3cd53622e6"
EXPECTED_SHA256_WINDOWS="f59482589a211e3fc4368c4750dfa50603f03c0acdf3d157728a41ac1ca19974"
EXPECTED_SHA256_MACOS="197337f2bc2ff2476abc988672cf5b20b381f5e12e9069f37dbd3fd157f7020e"

# ---------------------------------------------------------------------------

FAILED=0
RESULTS=()

# extract <expected-string> <file> <label> [<grep-pattern>]
#   Records OK or FAIL into RESULTS and updates FAILED accordingly.
#   Grep-pattern defaults to literal expected; pass a regex to relax.
extract() {
    local expected=$1
    local file=$2
    local label=$3
    local pattern=${4:-$expected}

    if [[ ! -f "$file" ]]; then
        RESULTS+=("MISS  $label  (file not found: $file)")
        FAILED=1
        return
    fi
    if grep -qE "$pattern" "$file"; then
        RESULTS+=("OK    $label  ($expected)")
    else
        RESULTS+=("FAIL  $label  (expected '$expected' not found in $file)")
        FAILED=1
    fi
}

# ---- (1) canonical: deploy/cloud/STATE.md ----------------------------------

CLOUD_STATE="$META_REPO/deploy/cloud/STATE.md"
extract "$EXPECTED_VERSION_UNDERSCORE" "$CLOUD_STATE" \
    "cloud STATE.md Linux vendor"  "DingRTC_Linux_SDK_${EXPECTED_VERSION_UNDERSCORE}"
extract "$EXPECTED_VERSION_UNDERSCORE" "$CLOUD_STATE" \
    "cloud STATE.md Windows vendor" "DingRTC_Windows_SDK_${EXPECTED_VERSION_UNDERSCORE}"
extract "$EXPECTED_VERSION_UNDERSCORE" "$CLOUD_STATE" \
    "cloud STATE.md macOS vendor"   "DingRTC_macOS_SDK_${EXPECTED_VERSION_UNDERSCORE}"
extract "$EXPECTED_SHA256_LINUX"      "$CLOUD_STATE" \
    "cloud STATE.md Linux sha256"
extract "$EXPECTED_SHA256_WINDOWS"    "$CLOUD_STATE" \
    "cloud STATE.md Windows sha256"
extract "$EXPECTED_SHA256_MACOS"      "$CLOUD_STATE" \
    "cloud STATE.md macOS sha256"

# ---- (2) deploy/cloud/scripts/install-dingrtc-sdk.sh -----------------------

INSTALL_SCRIPT="$META_REPO/deploy/cloud/scripts/install-dingrtc-sdk.sh"
extract "VERSION=\${ISALES_DINGRTC_SDK_VERSION:-${EXPECTED_VERSION}}" \
    "$INSTALL_SCRIPT" \
    "install-dingrtc-sdk.sh default VERSION" \
    "VERSION=\\\$\\{ISALES_DINGRTC_SDK_VERSION:-${EXPECTED_VERSION}\\}"
extract "$EXPECTED_SHA256_LINUX" "$INSTALL_SCRIPT" \
    "install-dingrtc-sdk.sh canonical sha256 (in docstring)"

# ---- (3) deploy/RUNBOOK-cloud.md ------------------------------------------

RUNBOOK_CLOUD="$META_REPO/deploy/RUNBOOK-cloud.md"
extract "DingRTC_Linux_SDK_${EXPECTED_VERSION_UNDERSCORE}" "$RUNBOOK_CLOUD" \
    "RUNBOOK-cloud Linux zip name"
extract "$EXPECTED_SHA256_LINUX" "$RUNBOOK_CLOUD" \
    "RUNBOOK-cloud Linux sha256"

# ---- (4) isales-engine build-dingrtc-binding.sh ----------------------------

BUILD_BINDING="$ENGINE_REPO/deploy/cloud/scripts/build-dingrtc-binding.sh"
if [[ -f "$BUILD_BINDING" ]]; then
    extract "DingRTC_Linux_SDK_${EXPECTED_VERSION_UNDERSCORE}" "$BUILD_BINDING" \
        "build-dingrtc-binding.sh default SDK path"
else
    RESULTS+=("SKIP  build-dingrtc-binding.sh (sibling isales-engine not at $ENGINE_REPO)")
fi

# ---- (5) isales-telephony pyproject.toml -----------------------------------

TELEPHONY_PYPROJECT="$TELEPHONY_REPO/pyproject.toml"
if [[ -f "$TELEPHONY_PYPROJECT" ]]; then
    extract "DingRTC_macOS_SDK_${EXPECTED_VERSION_UNDERSCORE}" "$TELEPHONY_PYPROJECT" \
        "telephony pyproject macos-dingrtc extras path"
else
    RESULTS+=("SKIP  telephony pyproject (sibling not at $TELEPHONY_REPO)")
fi

# ---- (6) isales-telephony Windows STATE.md ---------------------------------

WINDOWS_STATE="$TELEPHONY_REPO/deploy/edge/windows/STATE.md"
if [[ -f "$WINDOWS_STATE" ]]; then
    extract "DingRTC_Windows_SDK_${EXPECTED_VERSION_UNDERSCORE}" "$WINDOWS_STATE" \
        "Windows STATE.md post-§ 7 target version"
else
    RESULTS+=("SKIP  Windows STATE.md (sibling not at $WINDOWS_STATE)")
fi

# ---- (7) isales-telephony macOS RUNBOOK.md ---------------------------------

MACOS_RUNBOOK="$TELEPHONY_REPO/deploy/edge/macos/RUNBOOK.md"
if [[ -f "$MACOS_RUNBOOK" ]]; then
    extract "DingRTC_macOS_SDK_${EXPECTED_VERSION_UNDERSCORE}" "$MACOS_RUNBOOK" \
        "macOS RUNBOOK Linux/macOS vendor path"
    extract "$EXPECTED_SHA256_MACOS" "$MACOS_RUNBOOK" \
        "macOS RUNBOOK macOS sha256"
else
    RESULTS+=("SKIP  macOS RUNBOOK (sibling not at $MACOS_RUNBOOK)")
fi

# ---- archive-order invariant (§ 10.3) --------------------------------------
#
# The DingRTC migration retires the sidecar-pump model wholesale, so
# `engine-artc-sdk-thread-model` MUST archive before `engine-rtc-dingrtc-
# migration` archives. § 11.1 already moved it to archive/, so the active
# dir should no longer exist. If a future revert resurfaces the active
# folder, this assertion fires before the spec drift propagates.
THREAD_MODEL_ACTIVE_DIR="$META_REPO/openspec/changes/engine-artc-sdk-thread-model"
if [[ -d "$THREAD_MODEL_ACTIVE_DIR" ]]; then
    RESULTS+=("FAIL  archive-order  ('engine-artc-sdk-thread-model' is back in active changes/; it MUST be archived before 'engine-rtc-dingrtc-migration' archives — see § 11.1 / § 10.3)")
    FAILED=1
else
    RESULTS+=("OK    archive-order  (engine-artc-sdk-thread-model is archived, not active)")
fi

# ---- summary ---------------------------------------------------------------

echo "=== check_dingrtc_versions.sh — expected ${EXPECTED_VERSION} ==="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo

if [[ $FAILED -ne 0 ]]; then
    echo "FAIL: DingRTC version strings do not agree across all sources."
    echo "      The canonical source is deploy/cloud/STATE.md § DingRTC SDK vendor."
    echo "      Reconcile mismatched files; if the canonical version itself"
    echo "      changed, update EXPECTED_VERSION + EXPECTED_SHA256_* at the top"
    echo "      of this script."
    exit 1
fi
echo "PASS: all sources agree on DingRTC ${EXPECTED_VERSION}."
exit 0
