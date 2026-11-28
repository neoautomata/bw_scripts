#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH="" cd -- "${SCRIPT_DIR}/.." && pwd)"
BW_BIN="${REPO_ROOT}/bw"

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Create an isolated test environment with mock keyctl, bw.sess, and bw.bin.
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
        if [[ -f "${state}/keyctl_request_empty_once" ]]; then
            rm -f "${state}/keyctl_request_empty_once"
            exit 0
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
if [[ -f "${state}/bw_sess_exit" ]]; then
    echo "mock bw.sess failure" >&2
    exit "$(cat "${state}/bw_sess_exit")"
fi
if [[ -f "${state}/bw_sess_fail" ]]; then
    echo "mock bw.sess failure" >&2
    exit 1
fi
if [[ -f "${state}/bw_sess_remove_key" ]]; then
    rm -f "${state}/key_id" "${state}/key_value"
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

test_zero_arguments_bypass_bw_sess_and_keyring() {
    invoke_bw "${MOCK_BIN}:${PATH}"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "0" "$(cat "${STATE_DIR}/captured_argc")" "zero args passed to bw.bin"
    assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "BW_SESSION must stay empty"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "zero args must not call bw.sess"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "zero args must not call keyctl"
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
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess ran"
}

test_keyctl_request_empty_triggers_bw_sess() {
    printf '777\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'fresh-after-empty' > "${STATE_DIR}/bw_sess_key_value"
    touch "${STATE_DIR}/keyctl_request_empty_once"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code after empty request recovery"
    assert_eq "fresh-after-empty" "$(cat "${STATE_DIR}/captured_bw_session")" "recovered session token"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess ran after empty request"

    setup_env
    touch "${STATE_DIR}/keyctl_request_empty"
    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code when request stays empty"
    assert_contains "${STDERR}" "bw_session" "stderr mentions bw_session"
}

test_preserves_nonzero_exit_code() {
    printf '10\n' > "${STATE_DIR}/key_id"
    printf 'tok-exit' > "${STATE_DIR}/key_value"
    printf '42\n' > "${STATE_DIR}/bw_bin_exit"

    invoke_bw "${MOCK_BIN}:${PATH}" get item missing
    assert_eq "42" "${RC}" "exit code preserved"
}

test_custom_and_boundary_timeouts_and_empty_env_vars() {
    printf '55\n' > "${STATE_DIR}/key_id"
    printf 'tok-timeout' > "${STATE_DIR}/key_value"

    BW_SESSION_TIMEOUT=1 invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "min timeout exit code"
    assert_eq "55 1" "$(cat "${STATE_DIR}/timeout.log")" "min timeout value"

    : > "${STATE_DIR}/timeout.log"
    BW_SESSION_TIMEOUT=3600 invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "custom timeout exit code"
    assert_eq "55 3600" "$(cat "${STATE_DIR}/timeout.log")" "custom timeout value"

    : > "${STATE_DIR}/timeout.log"
    BW_SESSION_TIMEOUT=86400 invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "max timeout exit code"
    assert_eq "55 86400" "$(cat "${STATE_DIR}/timeout.log")" "max timeout value"

    : > "${STATE_DIR}/timeout.log"
    : > "${STATE_DIR}/calls.log"
    BW_SESSION_TIMEOUT="" BW_KEYRING="" invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "empty env vars exit code"
    assert_eq "55 900" "$(cat "${STATE_DIR}/timeout.log")" "empty timeout defaults to 900"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl [request] [user] [bw_session] [@u]" "empty keyring defaults to @u"
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

    # Leading global flags before lock and logout must still revoke and unlink the key.
    setup_env
    printf '89\n' > "${STATE_DIR}/key_id"
    BW_SESSION="stale-env-token" invoke_bw "${MOCK_BIN}:${PATH}" --quiet lock
    assert_eq "0" "${RC}" "--quiet lock exit code"
    assert_eq "89" "$(cat "${STATE_DIR}/revoke.log")" "--quiet lock revoked key"
    assert_eq "89 @u" "$(cat "${STATE_DIR}/unlink.log")" "--quiet lock unlinked key"
    assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "--quiet lock unset BW_SESSION"

    setup_env
    printf '90\n' > "${STATE_DIR}/key_id"
    BW_KEYRING="@s" BW_SESSION="stale-env-token" invoke_bw "${MOCK_BIN}:${PATH}" --nointeraction logout
    assert_eq "0" "${RC}" "--nointeraction logout on @s exit code"
    assert_eq "90" "$(cat "${STATE_DIR}/revoke.log")" "--nointeraction logout revoked key"
    assert_eq "90 @s" "$(cat "${STATE_DIR}/unlink.log")" "--nointeraction logout unlinked from @s"
    assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "--nointeraction logout unset BW_SESSION"

    # Missing key on lock must succeed cleanly without revoke or unlink errors.
    setup_env
    BW_SESSION="stale-env-token" invoke_bw "${MOCK_BIN}:${PATH}" lock
    assert_eq "0" "${RC}" "lock without cached key exits 0"
    assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "lock without key still unsets BW_SESSION"
    if [[ -f "${STATE_DIR}/revoke.log" || -f "${STATE_DIR}/unlink.log" ]]; then
        echo "Assertion failed: lock must not revoke or unlink when no key exists." >&2
        return 1
    fi
}

test_bypass_subcommands_and_flags_skip_bw_sess_and_keyring() {
    local subcmd
    for subcmd in --help -h --version -v help login unlock status config encode generate completion update; do
        setup_env
        invoke_bw "${MOCK_BIN}:${PATH}" "${subcmd}"
        assert_eq "0" "${RC}" "${subcmd} exit code"
        assert_eq "" "$(cat "${STATE_DIR}/captured_bw_session")" "${subcmd} must not set BW_SESSION"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "${subcmd} must not call bw.sess"
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "${subcmd} must not touch keyring"
    done

    # Leading global flags before bypass subcommands.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --raw status
    assert_eq "0" "${RC}" "--raw status exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--raw status must bypass keyring"

    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --nointeraction login
    assert_eq "0" "${RC}" "--nointeraction login exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--nointeraction login must bypass keyring"

    # Help flag after subcommand before -- bypasses bw.sess.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" list --help
    assert_eq "0" "${RC}" "list --help exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "list --help must bypass keyring"

    # Explicit --session token bypasses bw.sess and keyring.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --session tok list items
    assert_eq "0" "${RC}" "--session tok list items exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--session tok must bypass keyring"

    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --session=tok list items
    assert_eq "0" "${RC}" "--session=tok list items exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--session=tok must bypass keyring"

    # Flags after -- must not trigger help bypass.
    setup_env
    printf '44\n' > "${STATE_DIR}/key_id"
    printf 'auth-tok' > "${STATE_DIR}/key_value"
    invoke_bw "${MOCK_BIN}:${PATH}" get item -- --help
    assert_eq "0" "${RC}" "get item -- --help exit code"
    assert_eq "auth-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "get item -- --help must authenticate"
}

test_version_and_help_bypass_respect_subcommand_and_value_flags() {
    # Version flags before the subcommand bypass bw.sess and the keyring.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" -v
    assert_eq "0" "${RC}" "-v exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "-v must bypass keyring"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "-v must bypass bw.sess"

    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --raw -v
    assert_eq "0" "${RC}" "--raw -v exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--raw -v must bypass keyring"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "--raw -v must bypass bw.sess"

    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --pretty --version
    assert_eq "0" "${RC}" "--pretty --version exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "--pretty --version must bypass keyring"

    # Version flag after the subcommand or after --search must authenticate via bw.sess.
    setup_env
    printf '701\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'search-v-tok' > "${STATE_DIR}/bw_sess_key_value"
    invoke_bw "${MOCK_BIN}:${PATH}" list items --search -v
    assert_eq "0" "${RC}" "list items --search -v exit code"
    assert_eq "search-v-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "list items --search -v must authenticate"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "list items --search -v must call bw.sess"

    local args=()
    while IFS= read -r -d '' item; do
        args+=("${item}")
    done < "${STATE_DIR}/captured_args"
    assert_eq "4" "${#args[@]}" "list items --search -v arg count"
    assert_eq "list" "${args[0]}" "arg 0"
    assert_eq "items" "${args[1]}" "arg 1"
    assert_eq "--search" "${args[2]}" "arg 2"
    assert_eq "-v" "${args[3]}" "arg 3"

    # Bare -v after a subcommand must also authenticate.
    setup_env
    printf '702\n' > "${STATE_DIR}/key_id"
    printf 'subcmd-v-tok' > "${STATE_DIR}/key_value"
    invoke_bw "${MOCK_BIN}:${PATH}" list items -v
    assert_eq "0" "${RC}" "list items -v exit code"
    assert_eq "subcmd-v-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "list items -v must authenticate"

    # Help flags passed as values to --search must authenticate.
    local help_val
    for help_val in --help -h; do
        setup_env
        printf '703\n' > "${STATE_DIR}/key_id"
        printf 'search-help-tok' > "${STATE_DIR}/key_value"
        invoke_bw "${MOCK_BIN}:${PATH}" list items --search "${help_val}"
        assert_eq "0" "${RC}" "list items --search ${help_val} exit code"
        assert_eq "search-help-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "list items --search ${help_val} must authenticate"
    done

    # Help flag after the value of --search still bypasses bw.sess.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" list items --search foo --help
    assert_eq "0" "${RC}" "list items --search foo --help exit code"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "keyctl" "list items --search foo --help must bypass keyring"

    # Subcommand value flags before serve do not hide serve.
    setup_env
    invoke_bw "${MOCK_BIN}:${PATH}" --search serve
    assert_eq "1" "${RC}" "--search serve must fail closed"
    assert_contains "${STDERR}" "bw serve" "stderr explains serve refusal"
}

test_wrapper_active_guard_uses_string_comparison() {
    local pwn_file="${TEST_DIR}/arith_pwned"
    local val
    for val in "a[0]" "a[\$(touch ${pwn_file})]" "not-a-number" "01"; do
        setup_env
        _BW_WRAPPER_ACTIVE="${val}" invoke_bw "${MOCK_BIN}:${PATH}" status
        assert_eq "0" "${RC}" "non-1 _BW_WRAPPER_ACTIVE '${val}' exit code"
        assert_eq "" "${STDERR}" "non-1 _BW_WRAPPER_ACTIVE '${val}' produces no arithmetic error"
        assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin runs for '${val}'"
    done
    if [[ -e "${pwn_file}" ]]; then
        echo "Assertion failed: bash evaluated arithmetic expression in _BW_WRAPPER_ACTIVE." >&2
        return 1
    fi

    setup_env
    _BW_WRAPPER_ACTIVE="1" invoke_bw "${MOCK_BIN}:${PATH}" status
    assert_eq "1" "${RC}" "_BW_WRAPPER_ACTIVE=1 triggers recursion guard"
    assert_contains "${STDERR}" "recursive" "stderr mentions recursive call"
    if [[ -f "${STATE_DIR}/calls.log" ]]; then
        assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run on recursion guard"
    fi
}

test_serve_fails_closed_even_with_global_flags() {
    local -a cases=(
        "serve"
        "--quiet serve"
        "--raw serve"
        "--nointeraction serve"
        "--session tok serve"
        "--session=tok serve"
        "-- serve"
    )
    local entry
    local -a argv
    for entry in "${cases[@]}"; do
        setup_env
        printf '88\n' > "${STATE_DIR}/key_id"
        printf 'tok-serve' > "${STATE_DIR}/key_value"
        read -r -a argv <<< "${entry}"

        invoke_bw "${MOCK_BIN}:${PATH}" "${argv[@]}"
        assert_eq "1" "${RC}" "exit code for '${entry}'"
        assert_contains "${STDERR}" "bw serve" "stderr explains refusal for '${entry}'"
        if [[ -f "${STATE_DIR}/calls.log" ]]; then
            assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "'${entry}' must not call bw.sess"
            assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "'${entry}' must not call bw.bin"
        fi
    done
}

test_self_recursion_guards_reject_loop() {
    # Reject bw.bin symlink pointing directly to bw.
    local loop_bin="${TEST_DIR}/loop_bin"
    mkdir -p "${loop_bin}"
    cp "${MOCK_BIN}/keyctl" "${loop_bin}/keyctl"
    ln -s "${BW_BIN}" "${loop_bin}/bw.bin"

    invoke_bw "${loop_bin}:${PATH}" status
    assert_eq "1" "${RC}" "symlink loop exit code"
    assert_contains "${STDERR}" "bw.bin" "stderr mentions bw.bin loop"

    # Reject indirect recursion when bw.bin calls bw again.
    setup_env
    cat > "${MOCK_BIN}/bw.bin" << EOF
#!/usr/bin/env bash
exec "${BASH}" "${BW_BIN}" "\$@"
EOF
    chmod +x "${MOCK_BIN}/bw.bin"

    invoke_bw "${MOCK_BIN}:${PATH}" status
    assert_eq "1" "${RC}" "indirect recursion exit code"
    assert_contains "${STDERR}" "recursive" "stderr mentions recursive call"
}

test_missing_bw_sess_exits_one() {
    local no_sess_bin="${TEST_DIR}/no_sess_bin"
    mkdir -p "${no_sess_bin}"
    cp "${MOCK_BIN}/keyctl" "${no_sess_bin}/keyctl"
    cp "${MOCK_BIN}/bw.bin" "${no_sess_bin}/bw.bin"

    invoke_bw "${no_sess_bin}" list items
    assert_eq "1" "${RC}" "missing bw.sess exit code"
    assert_contains "${STDERR}" "bw.sess is not in PATH" "stderr mentions missing bw.sess"
}

test_propagates_bw_sess_exit_code() {
    printf '2\n' > "${STATE_DIR}/bw_sess_exit"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "2" "${RC}" "propagated exit code 2 on initial bw.sess failure"
    assert_contains "${STDERR}" "bw.sess failed" "stderr mentions bw.sess failure"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run"
}

test_toctou_retry_recovers_and_handles_failures() {
    # Recovers after timeout failure.
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    printf '34\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'new-tok' > "${STATE_DIR}/bw_sess_key_value"
    touch "${STATE_DIR}/keyctl_timeout_fail_once"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code after timeout retry"
    assert_eq "new-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "recovered session token"
    assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "bw.sess ran on TOCTOU retry"

    # Recovers after pipe failure.
    setup_env
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    printf '56\n' > "${STATE_DIR}/bw_sess_key_id"
    printf 'pipe-recovered-tok' > "${STATE_DIR}/bw_sess_key_value"
    touch "${STATE_DIR}/keyctl_pipe_fail_once"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "0" "${RC}" "exit code after pipe retry"
    assert_eq "pipe-recovered-tok" "$(cat "${STATE_DIR}/captured_bw_session")" "recovered session token on pipe retry"

    # Propagates bw.sess exit code 2 on TOCTOU retry failure.
    setup_env
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    touch "${STATE_DIR}/keyctl_timeout_fail_once"
    printf '2\n' > "${STATE_DIR}/bw_sess_exit"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "2" "${RC}" "exit code 2 propagated on TOCTOU retry"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run after retry failure"

    # Exits 1 when key stays missing after TOCTOU retry bw.sess succeeds.
    setup_env
    printf '12\n' > "${STATE_DIR}/key_id"
    printf 'old-tok' > "${STATE_DIR}/key_value"
    touch "${STATE_DIR}/keyctl_timeout_fail_once"
    touch "${STATE_DIR}/bw_sess_remove_key"

    invoke_bw "${MOCK_BIN}:${PATH}" list items
    assert_eq "1" "${RC}" "exit code when key missing after retry"
    assert_contains "${STDERR}" "bw_session" "stderr mentions missing bw_session"
    assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.bin" "bw.bin must not run when key missing after retry"
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
run_case "passes zero arguments to bw.bin without calling bw.sess" test_zero_arguments_bypass_bw_sess_and_keyring
run_case "missing key triggers bw.sess and retries keyctl request" test_missing_key_triggers_bw_sess_and_retries
run_case "empty keyctl request triggers bw.sess and fails if still empty" test_keyctl_request_empty_triggers_bw_sess
run_case "preserves non-zero exit code from bw.bin" test_preserves_nonzero_exit_code
run_case "honors boundary BW_SESSION_TIMEOUT and empty environment variables" test_custom_and_boundary_timeouts_and_empty_env_vars
run_case "rejects invalid BW_SESSION_TIMEOUT values" test_invalid_timeout_values
run_case "validates BW_KEYRING option" test_keyring_option_validation
run_case "lock and logout revoke key with global flags, @s, and missing key" test_lock_and_logout_revoke_and_bypass_bw_sess
run_case "bypass subcommands and flags skip bw.sess and keyring" test_bypass_subcommands_and_flags_skip_bw_sess_and_keyring
run_case "version and help bypasses respect subcommands and value-taking flags" test_version_and_help_bypass_respect_subcommand_and_value_flags
run_case "recursion guard uses string comparison for _BW_WRAPPER_ACTIVE" test_wrapper_active_guard_uses_string_comparison
run_case "bw serve fails closed even with leading global flags" test_serve_fails_closed_even_with_global_flags
run_case "rejects direct and indirect bw.bin self-recursion" test_self_recursion_guards_reject_loop
run_case "exits 1 when bw.sess is missing from PATH" test_missing_bw_sess_exits_one
run_case "propagates non-zero exit code 2 from bw.sess" test_propagates_bw_sess_exit_code
run_case "retries once via bw.sess on TOCTOU failure and handles retry errors" test_toctou_retry_recovers_and_handles_failures
run_case "exits 1 when bw.sess fails" test_bw_sess_fails
run_case "exits 1 when key is still missing after bw.sess" test_key_still_missing_after_bw_sess
run_case "exits 1 when keyctl timeout fails" test_keyctl_timeout_fails
run_case "exits 1 when keyctl pipe fails" test_keyctl_pipe_fails
run_case "exits 1 when keyctl pipe returns empty key" test_keyctl_pipe_returns_empty
run_case "exits 1 when keyctl is missing from PATH" test_missing_keyctl_in_path
run_case "exits 1 when bw.bin is missing from PATH" test_missing_bw_bin_in_path

echo "test_bw.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
