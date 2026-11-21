#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BW_BIN="${REPO_ROOT}/bw"

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Create a fresh isolated test environment with mock keyctl, bw.sess, and bw.bin.
setup_env() {
    TEST_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    MOCK_BIN="${TEST_DIR}/bin"
    STATE_DIR="${TEST_DIR}/state"
    mkdir -p "${MOCK_BIN}" "${STATE_DIR}"

    cat > "${MOCK_BIN}/keyctl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
printf 'keyctl' >> "${state}/calls.log"
for arg in "$@"; do
    printf ' [%s]' "${arg}" >> "${state}/calls.log"
done
printf '\n' >> "${state}/calls.log"

cmd="${1:-}"
case "${cmd}" in
    request)
        if [[ -f "${state}/keyctl_request_fail" ]]; then
            exit 1
        fi
        if [[ -f "${state}/keyctl_request_empty" ]]; then
            exit 0
        fi
        if [[ -f "${state}/key_id" ]]; then
            cat "${state}/key_id"
            exit 0
        fi
        exit 1
        ;;
    timeout)
        printf '%s %s\n' "${2:-}" "${3:-}" >> "${state}/timeout.log"
        if [[ -f "${state}/keyctl_timeout_fail_once" ]]; then
            rm -f "${state}/keyctl_timeout_fail_once"
            exit 1
        fi
        if [[ -f "${state}/keyctl_timeout_fail" ]]; then
            exit 1
        fi
        exit 0
        ;;
    pipe)
        if [[ -f "${state}/keyctl_pipe_fail_once" ]]; then
            rm -f "${state}/keyctl_pipe_fail_once"
            exit 1
        fi
        if [[ -f "${state}/keyctl_pipe_fail" ]]; then
            exit 1
        fi
        if [[ -f "${state}/key_value" ]]; then
            cat "${state}/key_value"
        fi
        exit 0
        ;;
    revoke)
        printf '%s\n' "${2:-}" >> "${state}/revoke.log"
        exit 0
        ;;
    unlink)
        printf '%s %s\n' "${2:-}" "${3:-}" >> "${state}/unlink.log"
        exit 0
        ;;
    *)
        echo "Unexpected keyctl subcommand: ${cmd}" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "${MOCK_BIN}/keyctl"

    cat > "${MOCK_BIN}/bw.sess" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
echo "bw.sess" >> "${state}/calls.log"
if [[ -f "${state}/bw_sess_fail" ]]; then
    echo "mock bw.sess failure" >&2
    exit 1
fi
if [[ -f "${state}/bw_sess_key_id" ]]; then
    cp "${state}/bw_sess_key_id" "${state}/key_id"
fi
if [[ -f "${state}/bw_sess_key_value" ]]; then
    cp "${state}/bw_sess_key_value" "${state}/key_value"
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/bw.sess"

    cat > "${MOCK_BIN}/bw.bin" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
echo "bw.bin" >> "${state}/calls.log"
printf '%s' "${BW_SESSION:-}" > "${state}/captured_bw_session"
printf '%d\n' "$#" > "${state}/captured_argc"
: > "${state}/captured_args"
for arg in "$@"; do
    printf '%s\0' "${arg}" >> "${state}/captured_args"
done
if [[ -f "${state}/bw_bin_stdout" ]]; then
    cat "${state}/bw_bin_stdout"
fi
if [[ -f "${state}/bw_bin_exit" ]]; then
    exit "$(cat "${state}/bw_bin_exit")"
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/bw.bin"
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "Assertion failed (${msg}): expected '${haystack}' not to contain '${needle}'." >&2
        return 1
    fi
}

# Run bw with the mock PATH and capture stdout, stderr, and exit code.
invoke_bw() {
    local custom_path="${1}"
    shift
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    MOCK_STATE_DIR="${STATE_DIR}" PATH="${custom_path}" "${BASH}" "${BW_BIN}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDOUT="$(cat "${OUT_FILE}")"
    STDERR="$(cat "${ERR_FILE}")"
}

test_existing_key_refreshes_timeout_and_runs_bw_bin() {
    printf '12345\n' > "${STATE_DIR}/key_id"
    printf 'secret-session-token' > "${STATE_DIR}/key_value"
    printf 'vault-output\n' > "${STATE_DIR}/bw_bin_stdout"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code"
    assert_eq "vault-output" "${STDOUT}" "stdout"
    assert_eq "" "${STDERR}" "stderr"
    assert_eq "secret-session-token" "$(cat "${STATE_DIR}/captured_bw_session")" "BW_SESSION value"
    assert_eq "12345 900" "$(cat "${STATE_DIR}/timeout.log")" "default timeout refresh"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess must not run"
}

test_preserves_complex_arguments() {
    printf '99\n' > "${STATE_DIR}/key_id"
    printf 'tok-123' > "${STATE_DIR}/key_value"

    invoke_bw "${MOCK_BIN}:${PATH}" get item "hello world" "it's \"quoted\"" '*' '?' '[a-z]' "--raw" ""
    assert_eq "0" "${RC}" "exit code"
    assert_eq "9" "$(cat "${STATE_DIR}/captured_argc")" "argument count"

    local args=()
    while IFS= read -r -d '' item; do
        args+=("${item}")
    done < "${STATE_DIR}/captured_args"

    assert_eq "get" "${args[0]}" "arg 0"
    assert_eq "item" "${args[1]}" "arg 1"
    assert_eq "hello world" "${args[2]}" "arg with space"
    assert_eq "it's \"quoted\"" "${args[3]}" "arg with quotes"
    assert_eq '*' "${args[4]}" "glob star"
    assert_eq '?' "${args[5]}" "glob question"
    assert_eq '[a-z]' "${args[6]}" "glob bracket"
    assert_eq "--raw" "${args[7]}" "flag arg"
    assert_eq "" "${args[8]}" "empty arg"
}

test_zero_arguments_passed_through() {
    printf '99\n' > "${STATE_DIR}/key_id"
    printf 'tok-zero' > "${STATE_DIR}/key_value"

    invoke_bw "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "0" "$(cat "${STATE_DIR}/captured_argc")" "zero args passed through"
}

test_missing_key_triggers_bw_sess_and_retries() {
    printf '777\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'fresh-session-key' > "${STATE_DIR}/bw_sess_key_value"
    printf 'ok\n' > "${STATE_DIR}/bw_bin_stdout"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code"
    assert_eq "ok" "${STDOUT}" "stdout"
    assert_eq "fresh-session-key" "$(cat "${STATE_DIR}/captured_bw_session")" "BW_SESSION from bw.sess"
    assert_eq "777 900" "$(cat "${STATE_DIR}/timeout.log")" "timeout refreshed on new key"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess was invoked"
}

test_preserves_nonzero_exit_code() {
    printf '10\n' > "${STATE_DIR}/key_id"
    printf 'tok-exit' > "${STATE_DIR}/key_value"
    printf '42\n' > "${STATE_DIR}/bw_bin_exit"

    invoke_bw "${MOCK_BIN}:${PATH}" get item missing
    assert_eq "42" "${RC}" "exit code preserved"
}

test_custom_timeout() {
    printf '55\n' > "${STATE_DIR}/key_id"
    printf 'tok-timeout' > "${STATE_DIR}/key_value"

    BW_SESSION_TIMEOUT=3600 invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code"
    assert_eq "55 3600" "$(cat "${STATE_DIR}/timeout.log")" "custom timeout value"

    BW_SESSION_TIMEOUT=86400 invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "max timeout exit code"
    assert_contains "$(cat "${STATE_DIR}/timeout.log")" "55 86400" "max timeout value"
}

test_invalid_timeout_values() {
    local bad_val
    for bad_val in "0" "-5" "abc" "10s" "0900" "86401" "4294967296" "999999"; do
        BW_SESSION_TIMEOUT="${bad_val}" invoke_bw "${MOCK_BIN}:${PATH}" list items
        assert_eq "1" "${RC}" "exit code for timeout '${bad_val}'"
        assert_contains "${STDERR}" "BW_SESSION_TIMEOUT" "stderr for timeout '${bad_val}'"
    done
}

test_keyring_option_validation() {
    printf '55\n' > "${STATE_DIR}/key_id"
    printf 'tok-session-ring' > "${STATE_DIR}/key_value"

    BW_KEYRING="@s" invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code for @s"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl [request] [user] [bw_session] [@s]" "requested @s keyring"

    local bad_ring
    for bad_ring in "@p" "@us" "12345" "invalid"; do
        BW_KEYRING="${bad_ring}" invoke_bw "${MOCK_BIN}:${PATH}" list items
        assert_eq "1" "${RC}" "exit code for keyring '${bad_ring}'"
        assert_contains "${STDERR}" "BW_KEYRING" "stderr for keyring '${bad_ring}'"
    done
}

test_lock_and_logout_revoke_and_bypass_bw_sess() {
    local subcmd
    for subcmd in lock logout; do
        setup_env
        printf '88\n' > "${STATE_DIR}/key_id"
        printf 'tok-old' > "${STATE_DIR}/key_value"

        BW_SESSION="stale-env-token" invoke_bw "${MOCK_BIN}:${PATH}" "${subcmd}"
        assert_eq "0" "${RC}" "${subcmd} exit code"
        assert_eq "88" "$(cat "${STATE_DIR}/revoke.log")" "${subcmd} revoked key"
        assert_eq "88 @u" "$(cat "${STATE_DIR}/unlink.log")" "${subcmd} unlinked key"
        assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "${subcmd} unset BW_SESSION"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "${subcmd} must not call bw.sess"
    done
}

test_bypass_subcommands_skip_bw_sess_and_keyring() {
    local subcmd
    for subcmd in --help -h --version -v help login unlock status config; do
        setup_env
        invoke_bw "${MOCK_BIN}:${PATH}" "${subcmd}"
        assert_eq "0" "${RC}" "${subcmd} exit code"
        assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "${subcmd} must not inject BW_SESSION"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "${subcmd} must not call bw.sess"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "${subcmd} must not touch keyring"
    done
}

test_serve_fails_closed() {
    printf '88\n' > "${STATE_DIR}/key_id"
    printf 'tok-serve' > "${STATE_DIR}/key_value"

    invoke_bw "${MOCK_BIN}:${PATH}" serve
    assert_eq "1" "${RC}" "serve exit code"
    assert_contains "${STDERR}" "bw serve" "stderr explains refusal"
    if [[ -f "${STATE_DIR}/calls.log" ]]; then
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "serve must not call bw.sess"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "serve must not call bw.bin"
    fi
}

test_toctou_retry_recovers_on_timeout_or_pipe_failure() {
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    printf '34\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'new-tok' > "${STATE_DIR}/bw_sess_key_value"
    touch "${STATE_DIR}/keyctl_timeout_fail_once"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code after timeout retry"
    assert_eq "new-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "recovered session token"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess invoked on TOCTOU retry"

    setup_env
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    printf '56\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'pipe-recovered-tok' > "${STATE_DIR}/bw_sess_key_value"
    touch "${STATE_DIR}/keyctl_pipe_fail_once"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code after pipe retry"
    assert_eq "pipe-recovered-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "recovered session token on pipe retry"
}

test_bw_sess_fails() {
    touch "${STATE_DIR}/bw_sess_fail"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "bw.sess failed" "stderr message"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run"
}

test_key_still_missing_after_bw_sess() {
    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "bw_session" "stderr message"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run"
}

test_keyctl_timeout_fails() {
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'tok' > "${STATE_DIR}/key_value"
    touch "${STATE_DIR}/keyctl_timeout_fail"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "timeout" "stderr message"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run"
}

test_keyctl_pipe_fails() {
    printf '12\n' > "${STATE_DIR}/key_id"
    touch "${STATE_DIR}/keyctl_pipe_fail"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "read the session key" "stderr message"
}

test_keyctl_pipe_returns_empty() {
    printf '12\n' > "${STATE_DIR}/key_id"
    : > "${STATE_DIR}/key_value"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "empty" "stderr message"
}

test_missing_keyctl_in_path() {
    local min_bin="${TEST_DIR}/min_no_keyctl"
    mkdir -p "${min_bin}"
    cp "${MOCK_BIN}/bw.bin" "${min_bin}/bw.bin"

    invoke_bw "${min_bin}" status
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "keyctl" "stderr mentions keyctl"
}

test_missing_bw_bin_in_path() {
    local min_bin="${TEST_DIR}/min_no_bw_bin"
    mkdir -p "${min_bin}"
    cp "${MOCK_BIN}/keyctl" "${min_bin}/keyctl"

    invoke_bw "${min_bin}" status
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "bw.bin" "stderr mentions bw.bin"
}

run_case "existing key refreshes timeout and runs bw.bin" test_existing_key_refreshes_timeout_and_runs_bw_bin
run_case "preserves spaces, quotes, globs, --raw, and empty args" test_preserves_complex_arguments
run_case "passes zero arguments through to bw.bin" test_zero_arguments_passed_through
run_case "missing key triggers bw.sess and retries keyctl request" test_missing_key_triggers_bw_sess_and_retries
run_case "preserves non-zero exit code from bw.bin" test_preserves_nonzero_exit_code
run_case "honors custom BW_SESSION_TIMEOUT" test_custom_timeout
run_case "rejects invalid BW_SESSION_TIMEOUT values" test_invalid_timeout_values
run_case "validates BW_KEYRING option" test_keyring_option_validation
run_case "lock and logout revoke/unlink key and bypass bw.sess" test_lock_and_logout_revoke_and_bypass_bw_sess
run_case "help/status/login/unlock/config bypass bw.sess and keyring" test_bypass_subcommands_skip_bw_sess_and_keyring
run_case "bw serve fails closed without injecting BW_SESSION" test_serve_fails_closed
run_case "retries once via bw.sess on keyctl timeout or pipe TOCTOU failure" test_toctou_retry_recovers_on_timeout_or_pipe_failure
run_case "exits 1 when bw.sess fails" test_bw_sess_fails
run_case "exits 1 when key is still missing after bw.sess" test_key_still_missing_after_bw_sess
run_case "exits 1 when keyctl timeout fails" test_keyctl_timeout_fails
run_case "exits 1 when keyctl pipe fails" test_keyctl_pipe_fails
run_case "exits 1 when keyctl pipe returns empty key" test_keyctl_pipe_returns_empty
run_case "exits 1 when keyctl is missing from PATH" test_missing_keyctl_in_path
run_case "exits 1 when bw.bin is missing from PATH" test_missing_bw_bin_in_path

echo "test_bw.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
