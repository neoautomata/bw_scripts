#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

RUN_SHELLCHECK=1

usage() {
    cat << 'EOF'
Usage: run_tests.sh [options]

Discover and run all test suites in tests/test_*.sh.

Options:
  --no-shellcheck  Skip shellcheck static analysis.
  --help, -h       Show this help text and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-shellcheck)
            RUN_SHELLCHECK=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1." >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Discover test suites in deterministic C locale sort order.
suites=()
while IFS= read -r suite; do
    [[ -n "$suite" ]] && suites+=("$suite")
done < <(LC_ALL=C find "${SCRIPT_DIR}" -maxdepth 1 -type f -name 'test_*.sh' | LC_ALL=C sort)

if [[ "${#suites[@]}" -eq 0 ]]; then
    echo "Error: Found 0 test suites in ${SCRIPT_DIR}." >&2
    exit 1
fi

passed_suites=0
failed_suites=0
failed_names=()

echo "Running ${#suites[@]} test suite(s)..."
echo

for suite in "${suites[@]}"; do
    suite_name="${suite##*/}"
    echo "=== ${suite_name} ==="
    if bash "${suite}"; then
        echo "SUITE PASS: ${suite_name}"
        passed_suites=$((passed_suites + 1))
    else
        echo "SUITE FAIL: ${suite_name}" >&2
        failed_suites=$((failed_suites + 1))
        failed_names+=("${suite_name}")
    fi
    echo
done

shellcheck_status="skipped"
shellcheck_failed=0
if [[ "${RUN_SHELLCHECK}" -eq 1 ]]; then
    if command -v shellcheck >/dev/null 2>&1; then
        echo "=== shellcheck ==="
        sc_targets=()
        for candidate in \
            "${REPO_ROOT}/bw" \
            "${REPO_ROOT}/bw.sess" \
            "${REPO_ROOT}/bw.item.get" \
            "${REPO_ROOT}/bw.item.search" \
            "${REPO_ROOT}/bw.item.pass" \
            "${REPO_ROOT}/bw.item.field" \
            "${REPO_ROOT}/bw.item.attachmentID" \
            "${REPO_ROOT}/bw.item.privKeyID" \
            "${REPO_ROOT}/bw.item.pubKeyID" \
            "${REPO_ROOT}/bw.ssh" \
            "${REPO_ROOT}/bw.keysetup" \
            "${REPO_ROOT}/install.sh" \
            "${SCRIPT_DIR}/run_tests.sh" \
            "${suites[@]}"; do
            if [[ -f "${candidate}" ]]; then
                sc_targets+=("${candidate}")
            fi
        done

        if shellcheck "${sc_targets[@]}"; then
            echo "SHELLCHECK PASS: checked ${#sc_targets[@]} file(s)."
            shellcheck_status="passed"
        else
            echo "SHELLCHECK FAIL: shellcheck reported issues." >&2
            shellcheck_status="failed"
            shellcheck_failed=1
        fi
        echo
    else
        echo "shellcheck is not in PATH. Skipping static analysis."
        echo
    fi
fi

total_suites=$((passed_suites + failed_suites))
echo "Summary: ${passed_suites}/${total_suites} test suite(s) passed, ${failed_suites} failed (shellcheck: ${shellcheck_status})."

if [[ "${failed_suites}" -gt 0 ]]; then
    echo "Failed suites: ${failed_names[*]}" >&2
    exit 1
fi

if [[ "${shellcheck_failed}" -ne 0 ]]; then
    exit 1
fi

exit 0
