#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

EXPECTED_SCRIPTS=(
    bw
    bw.sess
    bw.item.get
    bw.item.search
    bw.item.pass
    bw.item.field
    bw.item.attachmentID
    bw.item.privKeyID
    bw.item.pubKeyID
    bw.ssh
    bw.keysetup
)

# Build an isolated PATH directory with real coreutils needed by install.sh and mocked prereqs.
setup_env() {
    TEST_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    MOCK_BIN="${TEST_DIR}/bin"
    mkdir -p "${MOCK_BIN}"

    local sys_tool resolved
    for sys_tool in bash cat dirname mkdir install mktemp mv rm; do
        resolved="$(command -v "${sys_tool}")"
        ln -s "${resolved}" "${MOCK_BIN}/${sys_tool}"
    done

    local mock_tool
    for mock_tool in jq keyctl ssh ssh-add ssh-keygen perl bw.bin; do
        cat > "${MOCK_BIN}/${mock_tool}" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "${MOCK_BIN}/${mock_tool}"
    done
}

run_case() {
    local name="$1"
    shift
    setup_env
    if ( "$@" ); then
        echo "  PASS: ${name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${name}" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "${expected}" != "${actual}" ]]; then
        echo "Assertion failed (${msg}): expected '${expected}', got '${actual}'." >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "Assertion failed (${msg}): expected '${haystack}' to contain '${needle}'." >&2
        return 1
    fi
}

invoke_install() {
    local custom_path="$1"
    shift
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    PATH="${custom_path}" "${MOCK_BIN}/bash" "${INSTALL_SH}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDOUT="$(cat "${OUT_FILE}")"
    STDERR="$(cat "${ERR_FILE}")"
}

verify_installed_scripts() {
    local target_dir="$1"
    local script mode
    for script in "${EXPECTED_SCRIPTS[@]}"; do
        if [[ ! -f "${target_dir}/${script}" ]]; then
            echo "Assertion failed: missing installed script ${target_dir}/${script}." >&2
            return 1
        fi
        mode="$(stat -c '%a' "${target_dir}/${script}")"
        assert_eq "755" "${mode}" "permissions for ${script}"
        if ! cmp -s "${REPO_ROOT}/${script}" "${target_dir}/${script}"; then
            echo "Assertion failed: installed ${script} content differs from source." >&2
            return 1
        fi
    done
}

test_help_flag() {
    rm -f "${MOCK_BIN}/bw.bin" "${MOCK_BIN}/keyctl"

    invoke_install "${MOCK_BIN}" --help
    assert_eq "0" "${RC}" "--help exit code"
    assert_contains "${STDOUT}" "Usage: install.sh" "--help prints usage"

    invoke_install "${MOCK_BIN}" -h
    assert_eq "0" "${RC}" "-h exit code"
    assert_contains "${STDOUT}" "Usage: install.sh" "-h prints usage"
}

test_check_only_with_all_prereqs() {
    local unused_prefix="${TEST_DIR}/should_not_exist"
    invoke_install "${MOCK_BIN}" --prefix "${unused_prefix}" --check-only
    assert_eq "0" "${RC}" "exit code"
    assert_contains "${STDOUT}" "All required host tools exist." "stdout confirmation"
    if [[ -e "${unused_prefix}" ]]; then
        echo "Assertion failed: --check-only must not create prefix directory." >&2
        return 1
    fi
}

test_check_only_missing_bw_bin() {
    rm -f "${MOCK_BIN}/bw.bin"
    invoke_install "${MOCK_BIN}" --check-only
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "bw.bin" "stderr reports missing bw.bin"
}

test_check_only_missing_keyctl() {
    rm -f "${MOCK_BIN}/keyctl"
    invoke_install "${MOCK_BIN}" --check-only
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "keyctl" "stderr reports missing keyctl"
}

test_prefix_install_and_idempotency() {
    local target_dir="${TEST_DIR}/nested/install/bin"

    invoke_install "${MOCK_BIN}" --prefix "${target_dir}"
    assert_eq "0" "${RC}" "first install exit code"
    assert_contains "${STDOUT}" "Installed 11 scripts" "install summary"
    verify_installed_scripts "${target_dir}"

    # Re-run to verify idempotency.
    invoke_install "${MOCK_BIN}" --prefix "${target_dir}"
    assert_eq "0" "${RC}" "second install exit code"
    verify_installed_scripts "${target_dir}"
}

test_prefix_equals_syntax() {
    local target_dir="${TEST_DIR}/eq_bin"

    invoke_install "${MOCK_BIN}" "--prefix=${target_dir}"
    assert_eq "0" "${RC}" "--prefix=<dir> exit code"
    verify_installed_scripts "${target_dir}"
}

test_unknown_flag_exits_one() {
    invoke_install "${MOCK_BIN}" --unknown-flag
    assert_eq "1" "${RC}" "unknown flag exit code"
    assert_contains "${STDERR}" "Unknown option" "stderr error message"
    assert_contains "${STDERR}" "Usage: install.sh" "stderr usage"
}

test_missing_prefix_value_exits_one() {
    invoke_install "${MOCK_BIN}" --prefix
    assert_eq "1" "${RC}" "--prefix without value"
    assert_contains "${STDERR}" "--prefix requires a directory path" "stderr error"

    invoke_install "${MOCK_BIN}" --prefix ""
    assert_eq "1" "${RC}" "--prefix with empty value"
    assert_contains "${STDERR}" "--prefix requires a directory path" "stderr error"

    invoke_install "${MOCK_BIN}" "--prefix="
    assert_eq "1" "${RC}" "--prefix= with empty value"
    assert_contains "${STDERR}" "--prefix requires a directory path" "stderr error"
}

test_rejects_leading_dash_prefix() {
    invoke_install "${MOCK_BIN}" --prefix -foo
    assert_eq "1" "${RC}" "--prefix -foo exits 1"
    assert_contains "${STDERR}" "must not start with '-'" "stderr error for --prefix -foo"

    invoke_install "${MOCK_BIN}" "--prefix=-foo"
    assert_eq "1" "${RC}" "--prefix=-foo exits 1"
    assert_contains "${STDERR}" "must not start with '-'" "stderr error for --prefix=-foo"
}

test_rejects_symlink_prefix() {
    local real_dir="${TEST_DIR}/real_target"
    local link_dir="${TEST_DIR}/link_target"
    mkdir -p "${real_dir}"
    ln -s "${real_dir}" "${link_dir}"

    invoke_install "${MOCK_BIN}" --prefix "${link_dir}"
    assert_eq "1" "${RC}" "symlink prefix exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions symlink"
}

test_rejects_symlink_source_file() {
    local fake_repo="${TEST_DIR}/fake_repo"
    local target_dir="${TEST_DIR}/target_from_fake"
    mkdir -p "${fake_repo}"
    cp "${INSTALL_SH}" "${fake_repo}/install.sh"

    local script
    for script in "${EXPECTED_SCRIPTS[@]}"; do
        cp "${REPO_ROOT}/${script}" "${fake_repo}/${script}"
    done

    # Replace one source script with a symlink.
    rm -f "${fake_repo}/bw"
    ln -s "${REPO_ROOT}/bw" "${fake_repo}/bw"

    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    PATH="${MOCK_BIN}" "${MOCK_BIN}/bash" "${fake_repo}/install.sh" --prefix "${target_dir}" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDERR="$(cat "${ERR_FILE}")"

    assert_eq "1" "${RC}" "symlink source script exits 1"
    assert_contains "${STDERR}" "must be a regular file" "stderr mentions regular file"
}

test_rejects_empty_home_without_prefix() {
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    HOME="" PATH="${MOCK_BIN}" "${MOCK_BIN}/bash" "${INSTALL_SH}" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDERR="$(cat "${ERR_FILE}")"

    assert_eq "1" "${RC}" "empty HOME without --prefix exits 1"
    assert_contains "${STDERR}" "HOME is empty" "stderr mentions empty HOME"

    # Empty HOME with explicit --prefix succeeds.
    local target_dir="${TEST_DIR}/explicit_prefix"
    RC=0
    HOME="" PATH="${MOCK_BIN}" "${MOCK_BIN}/bash" "${INSTALL_SH}" --prefix "${target_dir}" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    assert_eq "0" "${RC}" "empty HOME with explicit --prefix succeeds"
    verify_installed_scripts "${target_dir}"
}

test_atomic_staging_leaves_no_temp_dir() {
    local target_dir="${TEST_DIR}/atomic_bin"
    invoke_install "${MOCK_BIN}" --prefix "${target_dir}"
    assert_eq "0" "${RC}" "install exit code"
    verify_installed_scripts "${target_dir}"

    local leftover
    leftover="$(find "${target_dir}" -maxdepth 1 -name '.bw-install.*' | wc -l | tr -d ' ')"
    assert_eq "0" "${leftover}" "no staging directory left behind"
}

run_case "--help and -h print usage and exit 0" test_help_flag
run_case "--check-only with all mocked prereqs exits 0" test_check_only_with_all_prereqs
run_case "--check-only with missing bw.bin reports error and exits 1" test_check_only_missing_bw_bin
run_case "--check-only with missing keyctl reports error and exits 1" test_check_only_missing_keyctl
run_case "--prefix <dir> installs all 11 scripts with 0755 and is idempotent" test_prefix_install_and_idempotency
run_case "--prefix=<dir> installs all 11 scripts with 0755" test_prefix_equals_syntax
run_case "unknown flag exits 1 with stderr error" test_unknown_flag_exits_one
run_case "missing or empty --prefix value exits 1 with stderr error" test_missing_prefix_value_exits_one
run_case "rejects --prefix starting with '-'" test_rejects_leading_dash_prefix
run_case "rejects symlink PREFIX directory" test_rejects_symlink_prefix
run_case "rejects symlink source script" test_rejects_symlink_source_file
run_case "rejects empty HOME when --prefix is omitted" test_rejects_empty_home_without_prefix
run_case "atomic staging removes temporary directory after install" test_atomic_staging_leaves_no_temp_dir

echo "test_install.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
