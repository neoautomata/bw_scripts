#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH="" cd -- "${SCRIPT_DIR}/.." && pwd)"
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

# Build an isolated PATH with real utilities needed by install.sh and mock host tools.
setup_env() {
    TEST_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    MOCK_BIN="${TEST_DIR}/bin"
    mkdir -p "${MOCK_BIN}"

    local sys_tool resolved
    for sys_tool in bash cat dirname mkdir install mktemp mv rm awk stat date; do
        resolved="$(command -v "${sys_tool}")"
        ln -s "${resolved}" "${MOCK_BIN}/${sys_tool}"
    done

    local mock_tool
    for mock_tool in jq keyctl ssh ssh-add ssh-agent ssh-keygen perl bw.bin; do
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
    set +e
    ( set -euo pipefail; "$@" )
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
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
    assert_contains "${STDOUT}" "--prefix=<dir>" "--help documents --prefix=<dir>"
    assert_contains "${STDOUT}" "-h" "--help documents -h"

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

test_check_only_missing_required_tools_and_gnu_date() {
    local tool
    for tool in bw.bin keyctl ssh-agent awk stat date install mktemp; do
        setup_env
        rm -f "${MOCK_BIN}/${tool}"
        invoke_install "${MOCK_BIN}" --check-only
        assert_eq "1" "${RC}" "missing ${tool} exits 1"
        assert_contains "${STDERR}" "${tool}" "stderr reports missing ${tool}"
    done

    # Reject non-GNU date that fails on --date.
    setup_env
    rm -f "${MOCK_BIN}/date"
    cat > "${MOCK_BIN}/date" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${MOCK_BIN}/date"

    invoke_install "${MOCK_BIN}" --check-only
    assert_eq "1" "${RC}" "non-GNU date exits 1"
    assert_contains "${STDERR}" "GNU --date" "stderr reports GNU --date requirement"
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

test_prefix_equals_syntax_and_spaces_and_default_home() {
    # --prefix=<dir> syntax.
    local target_dir="${TEST_DIR}/eq_bin"
    invoke_install "${MOCK_BIN}" "--prefix=${target_dir}"
    assert_eq "0" "${RC}" "--prefix=<dir> exit code"
    verify_installed_scripts "${target_dir}"

    # Target directory with spaces.
    local spaced_dir="${TEST_DIR}/dir with spaces/bin folder"
    invoke_install "${MOCK_BIN}" --prefix "${spaced_dir}"
    assert_eq "0" "${RC}" "spaced prefix exit code"
    verify_installed_scripts "${spaced_dir}"

    # Default $HOME/.local/bin install when --prefix is omitted.
    local fake_home="${TEST_DIR}/fake_home"
    mkdir -p "${fake_home}"
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    HOME="${fake_home}" PATH="${MOCK_BIN}" "${MOCK_BIN}/bash" "${INSTALL_SH}" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    assert_eq "0" "${RC}" "default HOME install exit code"
    verify_installed_scripts "${fake_home}/.local/bin"
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

test_rejects_symlink_prefix_trailing_slash_and_ancestors() {
    local real_dir="${TEST_DIR}/real_target"
    local link_dir="${TEST_DIR}/link_target"
    mkdir -p "${real_dir}"
    ln -s "${real_dir}" "${link_dir}"

    invoke_install "${MOCK_BIN}" --prefix "${link_dir}"
    assert_eq "1" "${RC}" "symlink prefix exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions symlink"

    invoke_install "${MOCK_BIN}" --prefix "${link_dir}/"
    assert_eq "1" "${RC}" "trailing-slash symlink prefix exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions symlink for trailing slash"

    invoke_install "${MOCK_BIN}" --prefix "${link_dir}/sub"
    assert_eq "1" "${RC}" "ancestor symlink prefix exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions symlink for ancestor"

    invoke_install "${MOCK_BIN}" --prefix "${link_dir}/sub/deep"
    assert_eq "1" "${RC}" "deep ancestor symlink prefix exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions symlink for deep ancestor"
}

test_rejects_non_directory_prefix_and_bad_destinations() {
    # Existing regular file at PREFIX.
    local reg_file="${TEST_DIR}/regular_file"
    printf 'content\n' > "${reg_file}"

    invoke_install "${MOCK_BIN}" --prefix "${reg_file}"
    assert_eq "1" "${RC}" "regular file PREFIX exits 1"
    assert_contains "${STDERR}" "not a directory" "stderr mentions not a directory"

    # Existing regular file as ancestor of PREFIX.
    invoke_install "${MOCK_BIN}" --prefix "${reg_file}/sub"
    assert_eq "1" "${RC}" "regular file ancestor exits 1"
    assert_contains "${STDERR}" "not a directory" "stderr mentions not a directory for ancestor"

    # Existing directory at ${PREFIX}/bw.
    local dir_dest="${TEST_DIR}/dir_dest"
    mkdir -p "${dir_dest}/bw"
    invoke_install "${MOCK_BIN}" --prefix "${dir_dest}"
    assert_eq "1" "${RC}" "directory at destination bw exits 1"
    assert_contains "${STDERR}" "must not be a directory" "stderr mentions destination directory"

    # Existing symlink to file at ${PREFIX}/bw.
    local link_file_dest="${TEST_DIR}/link_file_dest"
    mkdir -p "${link_file_dest}"
    ln -s "${reg_file}" "${link_file_dest}/bw"
    invoke_install "${MOCK_BIN}" --prefix "${link_file_dest}"
    assert_eq "1" "${RC}" "symlink file at destination bw exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions destination symlink"

    # Existing symlink to directory at ${PREFIX}/bw.
    local link_dir_dest="${TEST_DIR}/link_dir_dest"
    local other_dir="${TEST_DIR}/other_dir"
    mkdir -p "${link_dir_dest}" "${other_dir}"
    ln -s "${other_dir}" "${link_dir_dest}/bw"
    invoke_install "${MOCK_BIN}" --prefix "${link_dir_dest}"
    assert_eq "1" "${RC}" "symlink to directory at destination bw exits 1"
    assert_contains "${STDERR}" "must not be a symlink" "stderr mentions destination symlink to dir"
}

test_rejects_bw_bin_self_recursion() {
    # bw.bin pointing to source ${REPO_ROOT}/bw.
    rm -f "${MOCK_BIN}/bw.bin"
    ln -s "${REPO_ROOT}/bw" "${MOCK_BIN}/bw.bin"

    invoke_install "${MOCK_BIN}" --check-only
    assert_eq "1" "${RC}" "bw.bin pointing to repo bw fails --check-only"
    assert_contains "${STDERR}" "bw.bin must not point" "stderr explains bw.bin recursion"

    # bw.bin pointing to installed ${PREFIX}/bw.
    setup_env
    local target_dir="${TEST_DIR}/self_loop_prefix"
    mkdir -p "${target_dir}"
    cp "${REPO_ROOT}/bw" "${target_dir}/bw"
    rm -f "${MOCK_BIN}/bw.bin"
    ln -s "${target_dir}/bw" "${MOCK_BIN}/bw.bin"

    invoke_install "${MOCK_BIN}" --prefix "${target_dir}"
    assert_eq "1" "${RC}" "bw.bin pointing to target bw exits 1"
    assert_contains "${STDERR}" "bw.bin must not point" "stderr mentions target bw recursion"
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
    assert_eq "0" "${leftover}" "no staging directory remains"
}

test_signals_during_staging_remove_temp_dir_and_return_signal_code() {
    local real_install real_sleep real_perl spec sig expected_rc target_dir ready_file pid rc leftover
    real_install="$(command -v install)"
    real_sleep="$(command -v sleep)"
    real_perl="$(command -v perl)"

    for spec in "INT:130" "TERM:143" "HUP:129"; do
        sig="${spec%%:*}"
        expected_rc="${spec##*:}"
        setup_env
        target_dir="${TEST_DIR}/sig_${sig}_bin"
        ready_file="${TEST_DIR}/stage_ready_${sig}"

        rm -f "${MOCK_BIN}/install"
        cat > "${MOCK_BIN}/install" << EOF
#!/usr/bin/env bash
set -euo pipefail
: > "${ready_file}"
"${real_sleep}" 0.3
exec "${real_install}" "\$@"
EOF
        chmod +x "${MOCK_BIN}/install"

        # shellcheck disable=SC2016
        PATH="${MOCK_BIN}" \
            "${real_perl}" -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; $SIG{HUP}="DEFAULT"; exec @ARGV' \
            "${MOCK_BIN}/bash" "${INSTALL_SH}" --prefix "${target_dir}" >"${TEST_DIR}/stdout" 2>"${TEST_DIR}/stderr" &
        pid=$!

        local tries=0
        while [[ ! -f "${ready_file}" && "${tries}" -lt 100 ]]; do
            sleep 0.02
            tries=$((tries + 1))
        done
        if [[ ! -f "${ready_file}" ]]; then
            echo "Assertion failed: staging did not reach ready state for SIG${sig}." >&2
            return 1
        fi

        kill "-${sig}" "${pid}"
        rc=0
        wait "${pid}" || rc=$?

        assert_eq "${expected_rc}" "${rc}" "exit code on SIG${sig}"
        if [[ ! -d "${target_dir}" ]]; then
            echo "Assertion failed: target directory was not created for SIG${sig}." >&2
            return 1
        fi
        leftover="$(find "${target_dir}" -maxdepth 1 -name '.bw-install.*' | wc -l | tr -d ' ')"
        assert_eq "0" "${leftover}" "staging directory removed on SIG${sig}"
    done
}

run_case "--help and -h print usage including --prefix=<dir> and exit 0" test_help_flag
run_case "--check-only with all mocked prereqs exits 0" test_check_only_with_all_prereqs
run_case "--check-only rejects missing tools and non-GNU date" test_check_only_missing_required_tools_and_gnu_date
run_case "--prefix <dir> installs all 11 scripts with 0755 and is idempotent" test_prefix_install_and_idempotency
run_case "installs with --prefix=<dir>, spaces in path, and default HOME" test_prefix_equals_syntax_and_spaces_and_default_home
run_case "unknown flag exits 1 with stderr error" test_unknown_flag_exits_one
run_case "missing or empty --prefix value exits 1 with stderr error" test_missing_prefix_value_exits_one
run_case "rejects --prefix starting with '-'" test_rejects_leading_dash_prefix
run_case "rejects symlink PREFIX, trailing-slash symlink, and ancestor symlinks" test_rejects_symlink_prefix_trailing_slash_and_ancestors
run_case "rejects non-directory PREFIX and directory or symlink destinations" test_rejects_non_directory_prefix_and_bad_destinations
run_case "rejects bw.bin pointing to source or target bw script" test_rejects_bw_bin_self_recursion
run_case "rejects symlink source script" test_rejects_symlink_source_file
run_case "rejects empty HOME when --prefix is omitted" test_rejects_empty_home_without_prefix
run_case "atomic staging removes temporary directory after install" test_atomic_staging_leaves_no_temp_dir
run_case "SIGINT, SIGTERM, and SIGHUP remove staging directory and return signal code" test_signals_during_staging_remove_temp_dir_and_return_signal_code

echo "test_install.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
