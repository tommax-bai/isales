#!/usr/bin/env bash
# Run every iSales repo's test suite in sequence. Prints a per-repo
# summary line and a final "N passed / M failed" tally; exits non-zero
# if any repo's suite failed.
#
# Usage:
#   make test-all          # from the iSales main repo root
#   bash scripts/test_all.sh
#
# Pass-through args land on every pytest invocation (e.g. ``-k myfilter``).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIBLING_ROOT="$(cd "${WORKSPACE_ROOT}/.." && pwd)"

PY_REPOS=(
    "isales-common"
    "isales-api"
    "isales-telephony"
    "isales-scheduler"
    "isales-worker"
    "isales-engine"
)

JS_REPOS=(
    "isales-web"
)

OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_LIST=()
SUMMARY_LINES=()

start_total=$(date +%s)

run_python_repo() {
    local name="$1"
    shift
    local path="${SIBLING_ROOT}/${name}"
    if [[ ! -d "${path}" ]]; then
        SUMMARY_LINES+=("? ${name} — not found at ${path}")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if [[ ! -x "${path}/.venv/bin/python" ]]; then
        SUMMARY_LINES+=("? ${name} — no .venv (run: pip install -e \".[dev]\")")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    echo
    echo "==> ${name}"
    local start
    start=$(date +%s)
    local output
    output=$(cd "${path}" && .venv/bin/python -m pytest -q --no-header "$@" 2>&1)
    local rc=$?
    local elapsed=$(( $(date +%s) - start ))
    local last_line
    last_line=$(echo "${output}" | tail -1 | tr -d '\r')

    if [[ ${rc} -eq 0 ]]; then
        SUMMARY_LINES+=("✓ ${name} — ${last_line} (${elapsed}s)")
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "${output}"
        SUMMARY_LINES+=("✗ ${name} — ${last_line} (${elapsed}s)")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_LIST+=("${name}")
    fi
}

run_js_repo() {
    local name="$1"
    local path="${SIBLING_ROOT}/${name}"
    if [[ ! -d "${path}" ]]; then
        SUMMARY_LINES+=("? ${name} — not found at ${path}")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi
    if [[ ! -d "${path}/node_modules" ]]; then
        SUMMARY_LINES+=("? ${name} — no node_modules (run: npm install)")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    echo
    echo "==> ${name}"
    local start
    start=$(date +%s)
    local output
    output=$(cd "${path}" && npx vitest run --reporter=basic 2>&1)
    local rc=$?
    local elapsed=$(( $(date +%s) - start ))
    local last_line
    last_line=$(echo "${output}" | grep -E "Tests +[0-9]+" | tail -1 | tr -d '\r')
    if [[ -z "${last_line}" ]]; then
        last_line=$(echo "${output}" | tail -1 | tr -d '\r')
    fi

    if [[ ${rc} -eq 0 ]]; then
        SUMMARY_LINES+=("✓ ${name} — ${last_line} (${elapsed}s)")
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "${output}"
        SUMMARY_LINES+=("✗ ${name} — ${last_line} (${elapsed}s)")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_LIST+=("${name}")
    fi
}

for repo in "${PY_REPOS[@]}"; do
    run_python_repo "${repo}" "$@"
done

for repo in "${JS_REPOS[@]}"; do
    run_js_repo "${repo}"
done

elapsed_total=$(( $(date +%s) - start_total ))

echo
echo "================================================================"
echo "iSales test_all summary  (total ${elapsed_total}s)"
echo "================================================================"
for line in "${SUMMARY_LINES[@]}"; do
    echo "  ${line}"
done
echo "----------------------------------------------------------------"
echo "  ✓ ok=${OK_COUNT}  ✗ fail=${FAIL_COUNT}  ? skip=${SKIP_COUNT}"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo
    echo "Failed repos: ${FAILED_LIST[*]}"
    exit 1
fi
