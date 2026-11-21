#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BW_SESS="${REPO_ROOT}/bw.sess"

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

setup_env() {
    TEST_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    MOCK_BIN="${TEST_DIR}/bin"
    STATE_DIR="${TEST_DIR}/state"
    mkdir -p "${MOCK_BIN}" "${STATE_DIR}"

    # Poison wrapper to ensure bw.sess never invokes bw directly.
    cat > "${MOCK_BIN}/bw" << 'EOF'
#!/usr/bin/env bash
echo "bw-wrapper" >> "${MOCK_STATE_DIR}/calls.log"
echo "Unexpected call to bw wrapper" >&2
exit 98
EOF
    chmod +x "${MOCK_BIN}/bw"

    cat > "${MOCK_BIN}/keyctl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
printf 'keyctl %s\n' "$*" >> "${state}/calls.log"

cmd="${1:-}"
case "${cmd}" in
    request)
        if [[ -f "${state}/existing_key_id" ]]; then
            cat "${state}/existing_key_id"
            exit 0
        fi
        exit 1
        ;;
    pipe)
        if [[ -f "${state}/existing_key_value" ]]; then
            cat "${state}/existing_key_value"
            exit 0
        fi
        exit 1
        ;;
    padd)
        cat > "${state}/padd_stdin"
        if [[ -f "${state}/keyctl_padd_fail" ]]; then
            exit 1
        fi
        if [[ -f "${state}/keyctl_padd_empty" ]]; then
            exit 0
        fi
        printf '%s\n' "${MOCK_NEW_KEY_ID:-54321}"
        exit 0
        ;;
    setperm)
        printf '%s %s\n' "${2:-}" "${3:-}" >> "${state}/setperm.log"
        if [[ -f "${state}/keyctl_setperm_fail" ]]; then
            exit 1
        fi
        exit 0
        ;;
    timeout)
        printf '%s %s\n' "${2:-}" "${3:-}" >> "${state}/timeout.log"
        if [[ -f "${state}/keyctl_timeout_fail" ]]; then
            exit 1
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

    cat > "${MOCK_BIN}/bw.bin" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
printf 'bw.bin %s\n' "$*" >> "${state}/calls.log"

case "${1:-} ${2:-}" in
    "unlock --check")
        printf '%s' "${BW_SESSION:-}" > "${state}/unlock_check_session"
        if [[ -f "${state}/unlock_check_ok" ]]; then
            exit 0
        fi
        exit 1
        ;;
    "login --check")
        if [[ -f "${state}/login_check_fail" ]]; then
            exit 1
        fi
        exit 0
        ;;
    "login ")
        if [[ -f "${state}/login_stdout" ]]; then
            cat "${state}/login_stdout"
        fi
        if [[ -f "${state}/login_fail" ]]; then
            exit 1
        fi
        exit 0
        ;;
    "unlock --raw")
        if [[ -f "${state}/unlock_raw_fail" ]]; then
            exit 1
        fi
        if [[ -f "${state}/unlock_raw_key" ]]; then
            cat "${state}/unlock_raw_key"
        fi
        exit 0
        ;;
    "sync --last")
        printf '%s' "${BW_SESSION:-}" > "${state}/sync_last_session"
        if [[ -f "${state}/sync_last_fail" ]]; then
            exit 1
        fi
        if [[ -f "${state}/sync_last_value" ]]; then
            cat "${state}/sync_last_value"
        fi
        exit 0
        ;;
    "sync ")
        printf '%s' "${BW_SESSION:-}" > "${state}/sync_session"
        if [[ -f "${state}/sync_fail" ]]; then
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "Unexpected bw.bin invocation: $*" >&2
        exit 99
        ;;
esac
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

invoke_sess() {
    local custom_path="${1}"
    shift
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    MOCK_STATE_DIR="${STATE_DIR}" PATH="${custom_path}" "${BASH}" "${BW_SESS}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDOUT="$(cat "${OUT_FILE}")"
    STDERR="$(cat "${ERR_FILE}")"
}

iso_hours_ago() {
    local hours="$1"
    date -u --date="${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ'
}

test_existing_valid_key_exits_early() {
    printf '101\n' > "${STATE_DIR}/existing_key_id"
    printf 'valid-existing-key' > "${STATE_DIR}/existing_key_value"
    touch "${STATE_DIR}/unlock_check_ok"

    invoke_sess "${MOCK_BIN}:${PATH}"
    local calls
    calls="$(cat "${STATE_DIR}/calls.log")"

    assert_eq "0" "${RC}" "exit code"
    assert_eq "valid-existing-key" "$(cat "${STATE_DIR}/unlock_check_session")" "unlock --check received piped key"
    assert_not_contains "${calls}" "bw-wrapper" "must not call bw wrapper"
    assert_not_contains "${calls}" "bw.bin login" "must not call login"
    assert_not_contains "${calls}" "bw.bin unlock --raw" "must not call unlock --raw"
    assert_not_contains "${calls}" "keyctl padd" "must not call keyctl padd"
    assert_not_contains "${calls}" "bw.bin sync" "must not call sync"
}

test_stale_keyring_key_triggers_reauth() {
    printf '101\n' > "${STATE_DIR}/existing_key_id"
    printf 'stale-key' > "${STATE_DIR}/existing_key_value"
    printf 'fresh-key-after-stale' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    local calls
    calls="$(cat "${STATE_DIR}/calls.log")"

    assert_eq "0" "${RC}" "exit code"
    assert_contains "${calls}" "bw.bin unlock --check" "checked existing key"
    assert_eq "101" "$(cat "${STATE_DIR}/revoke.log")" "revoked stale key"
    assert_eq "101 @u" "$(cat "${STATE_DIR}/unlink.log")" "unlinked stale key"
    assert_contains "${calls}" "bw.bin unlock --raw" "re-unlocked vault"
    assert_eq "fresh-key-after-stale" "$(cat "${STATE_DIR}/padd_stdin")" "stored new key"
    assert_eq "54321 0x3f000000" "$(cat "${STATE_DIR}/setperm.log")" "setperm called"
    assert_eq "54321 900" "$(cat "${STATE_DIR}/timeout.log")" "timeout set"
}

test_stale_key_revoked_even_when_reunlock_fails() {
    printf '202\n' > "${STATE_DIR}/existing_key_id"
    printf 'stale-key' > "${STATE_DIR}/existing_key_value"
    touch "${STATE_DIR}/unlock_raw_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "2" "${RC}" "exit code on unlock failure"
    assert_eq "202" "$(cat "${STATE_DIR}/revoke.log")" "stale key revoked before unlock failure"
    assert_eq "202 @u" "$(cat "${STATE_DIR}/unlink.log")" "stale key unlinked before unlock failure"
}

test_already_logged_in_stores_exact_bytes_without_newline() {
    printf 'exactKeyBytes123' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    local calls
    calls="$(cat "${STATE_DIR}/calls.log")"

    assert_eq "0" "${RC}" "exit code"
    assert_not_contains "${calls}" "bw.bin login"$'\n' "skipped bw.bin login"
    assert_eq "16" "$(wc -c < "${STATE_DIR}/padd_stdin" | tr -d ' ')" "exact byte count without trailing newline"
    assert_eq "exactKeyBytes123" "$(cat "${STATE_DIR}/padd_stdin")" "exact stored bytes"
    assert_eq "54321 900" "$(cat "${STATE_DIR}/timeout.log")" "default timeout"
}

test_not_logged_in_runs_login_redirected_to_stderr() {
    touch "${STATE_DIR}/login_check_fail"
    printf 'Login prompt text\n' > "${STATE_DIR}/login_stdout"
    printf 'unlocked-key-42' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "" "${STDOUT}" "login stdout must not appear on stdout"
    assert_contains "${STDERR}" "Login prompt text" "login stdout redirected to stderr"
    assert_eq "unlocked-key-42" "$(cat "${STATE_DIR}/padd_stdin")" "stored unlocked key"
}

test_recent_sync_skips_sync() {
    printf 'sync-skip-key' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 2 > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    local calls
    calls="$(cat "${STATE_DIR}/calls.log")"

    assert_eq "0" "${RC}" "exit code"
    assert_contains "${calls}" "bw.bin sync --last" "checked last sync"
    assert_not_contains "${calls}" "bw.bin sync"$'\n' "skipped full sync"
}

test_old_sync_triggers_sync_with_new_key() {
    printf 'new-sync-key-99' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 10 > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "new-sync-key-99" "$(cat "${STATE_DIR}/sync_session")" "bw.bin sync received new BW_SESSION"
}

test_sync_last_empty_triggers_sync() {
    printf 'key-empty-sync' > "${STATE_DIR}/unlock_raw_key"
    : > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "key-empty-sync" "$(cat "${STATE_DIR}/sync_session")" "empty sync --last triggers sync"
}

test_sync_last_null_triggers_sync() {
    printf 'key-null-sync' > "${STATE_DIR}/unlock_raw_key"
    printf 'null\n' > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "key-null-sync" "$(cat "${STATE_DIR}/sync_session")" "null sync --last triggers sync"
}

test_sync_last_garbage_triggers_sync() {
    printf 'key-garbage-sync' > "${STATE_DIR}/unlock_raw_key"
    printf 'not-a-valid-timestamp\n' > "${STATE_DIR}/sync_last_value"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "key-garbage-sync" "$(cat "${STATE_DIR}/sync_session")" "garbage sync --last triggers sync"
}

test_sync_last_fails_triggers_sync() {
    printf 'key-fail-sync-last' > "${STATE_DIR}/unlock_raw_key"
    touch "${STATE_DIR}/sync_last_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "key-fail-sync-last" "$(cat "${STATE_DIR}/sync_session")" "failed sync --last triggers sync"
}

test_sync_failure_warns_and_exits_zero() {
    printf 'key-sync-warn' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 12 > "${STATE_DIR}/sync_last_value"
    touch "${STATE_DIR}/sync_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code remains 0 on sync failure"
    assert_contains "${STDERR}" "Warning" "warning printed to stderr"
}

test_login_failure_exits_one() {
    touch "${STATE_DIR}/login_check_fail"
    touch "${STATE_DIR}/login_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "login failed" "stderr message"
}

test_unlock_failure_exits_two() {
    touch "${STATE_DIR}/unlock_raw_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "2" "${RC}" "exit code"
    assert_contains "${STDERR}" "unlock failed" "stderr message"
}

test_unlock_empty_key_exits_two() {
    : > "${STATE_DIR}/unlock_raw_key"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "2" "${RC}" "exit code"
    assert_contains "${STDERR}" "unlock failed" "stderr message"
}

test_key_starting_with_dash_n_and_dash_e_stored_verbatim() {
    local tricky_key
    for tricky_key in "-n secret" "-e\nliteral"; do
        setup_env
        printf '%s' "${tricky_key}" > "${STATE_DIR}/unlock_raw_key"
        iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

        invoke_sess "${MOCK_BIN}:${PATH}"
        assert_eq "0" "${RC}" "exit code for '${tricky_key}'"
        if ! cmp -s "${STATE_DIR}/unlock_raw_key" "${STATE_DIR}/padd_stdin"; then
            echo "Assertion failed: padd_stdin bytes did not match '${tricky_key}'." >&2
            return 1
        fi
    done
}

test_keyctl_padd_fails_exits_nonzero() {
    printf 'some-key' > "${STATE_DIR}/unlock_raw_key"
    touch "${STATE_DIR}/keyctl_padd_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "store the session key" "stderr message"
}

test_keyctl_padd_empty_id_exits_nonzero() {
    printf 'some-key' > "${STATE_DIR}/unlock_raw_key"
    touch "${STATE_DIR}/keyctl_padd_empty"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "store the session key" "stderr message"
}

test_keyctl_setperm_fails_revokes_and_unlinks_key() {
    printf 'some-key' > "${STATE_DIR}/unlock_raw_key"
    touch "${STATE_DIR}/keyctl_setperm_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "permissions" "stderr message"
    assert_eq "54321" "$(cat "${STATE_DIR}/revoke.log")" "keyctl revoke called on setperm failure"
    assert_eq "54321 @u" "$(cat "${STATE_DIR}/unlink.log")" "keyctl unlink called on setperm failure"
}

test_keyctl_timeout_fails_unlinks_key() {
    printf 'some-key' > "${STATE_DIR}/unlock_raw_key"
    touch "${STATE_DIR}/keyctl_timeout_fail"

    invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "timeout" "stderr message"
    assert_eq "54321" "$(cat "${STATE_DIR}/revoke.log")" "keyctl revoke called on timeout failure"
    assert_eq "54321 @u" "$(cat "${STATE_DIR}/unlink.log")" "keyctl unlink called on timeout failure"
}

test_unexpected_cli_args_exits_one() {
    invoke_sess "${MOCK_BIN}:${PATH}" extra-arg
    assert_eq "1" "${RC}" "exit code"
    assert_contains "${STDERR}" "Usage:" "usage printed on stderr"
}

test_invalid_timeout_exits_one() {
    local bad_val
    for bad_val in "0" "-1" "abc" "010" "86401" "4294967296"; do
        BW_SESSION_TIMEOUT="${bad_val}" invoke_sess "${MOCK_BIN}:${PATH}"
        assert_eq "1" "${RC}" "exit code for '${bad_val}'"
        assert_contains "${STDERR}" "BW_SESSION_TIMEOUT" "stderr for '${bad_val}'"
    done
}

test_custom_timeout_passed_to_keyctl() {
    printf 'custom-timeout-key' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    BW_SESSION_TIMEOUT=1800 invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "54321 1800" "$(cat "${STATE_DIR}/timeout.log")" "custom timeout"

    setup_env
    printf 'max-timeout-key' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    BW_SESSION_TIMEOUT=86400 invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "max timeout exit code"
    assert_eq "54321 86400" "$(cat "${STATE_DIR}/timeout.log")" "max timeout"
}

test_keyring_option_validation() {
    printf 'session-ring-key' > "${STATE_DIR}/unlock_raw_key"
    iso_hours_ago 1 > "${STATE_DIR}/sync_last_value"

    BW_KEYRING="@s" invoke_sess "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code for @s"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl padd user bw_session @s" "padd targets @s"

    local bad_ring
    for bad_ring in "@p" "@us" "999" "bad"; do
        BW_KEYRING="${bad_ring}" invoke_sess "${MOCK_BIN}:${PATH}"
        assert_eq "1" "${RC}" "exit code for '${bad_ring}'"
        assert_contains "${STDERR}" "BW_KEYRING" "stderr for '${bad_ring}'"
    done
}

test_missing_keyctl_or_bw_bin() {
    local min_no_keyctl="${TEST_DIR}/no_keyctl"
    mkdir -p "${min_no_keyctl}"
    cp "${MOCK_BIN}/bw.bin" "${min_no_keyctl}/bw.bin"
    invoke_sess "${min_no_keyctl}"
    assert_eq "1" "${RC}" "exit code without keyctl"
    assert_contains "${STDERR}" "keyctl" "stderr mentions keyctl"

    local min_no_bw_bin="${TEST_DIR}/no_bw_bin"
    mkdir -p "${min_no_bw_bin}"
    cp "${MOCK_BIN}/keyctl" "${min_no_bw_bin}/keyctl"
    invoke_sess "${min_no_bw_bin}"
    assert_eq "1" "${RC}" "exit code without bw.bin"
    assert_contains "${STDERR}" "bw.bin" "stderr mentions bw.bin"
}

run_case "existing valid key exits early without login/unlock/padd/sync" test_existing_valid_key_exits_early
run_case "stale keyring key triggers re-authentication" test_stale_keyring_key_triggers_reauth
run_case "stale keyring key is revoked and unlinked even if re-unlock fails" test_stale_key_revoked_even_when_reunlock_fails
run_case "already logged in skips login and stores exact bytes" test_already_logged_in_stores_exact_bytes_without_newline
run_case "not logged in runs login with stdout redirected to stderr" test_not_logged_in_runs_login_redirected_to_stderr
run_case "last sync under 8 hours skips sync" test_recent_sync_skips_sync
run_case "last sync over 8 hours runs sync with new BW_SESSION" test_old_sync_triggers_sync_with_new_key
run_case "empty sync --last output triggers sync" test_sync_last_empty_triggers_sync
run_case "null sync --last output triggers sync" test_sync_last_null_triggers_sync
run_case "garbage sync --last output triggers sync without crashing" test_sync_last_garbage_triggers_sync
run_case "failing sync --last triggers sync without crashing" test_sync_last_fails_triggers_sync
run_case "bw.bin sync failure prints warning and exits 0" test_sync_failure_warns_and_exits_zero
run_case "bw.bin login failure exits 1" test_login_failure_exits_one
run_case "bw.bin unlock --raw failure exits 2" test_unlock_failure_exits_two
run_case "bw.bin unlock --raw empty output exits 2" test_unlock_empty_key_exits_two
run_case "keys starting with -n or -e are stored verbatim" test_key_starting_with_dash_n_and_dash_e_stored_verbatim
run_case "keyctl padd failure exits non-zero" test_keyctl_padd_fails_exits_nonzero
run_case "keyctl padd empty ID exits non-zero" test_keyctl_padd_empty_id_exits_nonzero
run_case "keyctl setperm failure revokes and unlinks key and exits 1" test_keyctl_setperm_fails_revokes_and_unlinks_key
run_case "keyctl timeout failure unlinks key and exits non-zero" test_keyctl_timeout_fails_unlinks_key
run_case "unexpected CLI args exit 1 with usage" test_unexpected_cli_args_exits_one
run_case "invalid BW_SESSION_TIMEOUT exits 1" test_invalid_timeout_exits_one
run_case "custom BW_SESSION_TIMEOUT is passed to keyctl" test_custom_timeout_passed_to_keyctl
run_case "BW_KEYRING accepts @s and rejects invalid values" test_keyring_option_validation
run_case "missing keyctl or bw.bin in PATH exits 1" test_missing_keyctl_or_bw_bin

echo "test_bw_sess.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
