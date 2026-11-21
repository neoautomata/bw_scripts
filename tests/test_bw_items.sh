#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

VALID_UUID="11111111-2222-3333-4444-555555555555"
VALID_UUID_2="abcdef01-2345-6789-abcd-ef0123456789"

setup_env() {
    TEST_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    MOCK_BIN="${TEST_DIR}/bin"
    STATE_DIR="${TEST_DIR}/state"
    mkdir -p "${MOCK_BIN}" "${STATE_DIR}"

    cat > "${MOCK_BIN}/bw" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE_DIR}"
printf '%d\n' "$#" > "${state}/bw_argc"
: > "${state}/bw_args"
for arg in "$@"; do
    printf '%s\0' "${arg}" >> "${state}/bw_args"
done
if [[ -f "${state}/bw_stderr" ]]; then
    cat "${state}/bw_stderr" >&2
fi
if [[ -f "${state}/bw_stdout" ]]; then
    cat "${state}/bw_stdout"
fi
if [[ -f "${state}/bw_exit" ]]; then
    exit "$(cat "${state}/bw_exit")"
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/bw"
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

invoke_script() {
    local script="$1"
    shift
    OUT_FILE="${TEST_DIR}/stdout"
    ERR_FILE="${TEST_DIR}/stderr"
    RC=0
    MOCK_STATE_DIR="${STATE_DIR}" PATH="${MOCK_BIN}:${REPO_ROOT}:${PATH}" \
        bash "${REPO_ROOT}/${script}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}" || RC=$?
    STDOUT="$(cat "${OUT_FILE}")"
    STDERR="$(cat "${ERR_FILE}")"
}

read_bw_args() {
    BW_ARGS=()
    while IFS= read -r -d '' item; do
        BW_ARGS+=("${item}")
    done < "${STATE_DIR}/bw_args"
}

# --- bw.item.get ---

test_item_get_happy_and_uuid_validation() {
    printf '{"id":"%s"}\n' "${VALID_UUID}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.get "${VALID_UUID}"
    read_bw_args
    assert_eq "0" "${RC}" "exit code"
    assert_eq "{\"id\":\"${VALID_UUID}\"}" "${STDOUT}" "stdout"
    assert_eq "4" "${#BW_ARGS[@]}" "argc"
    assert_eq "get" "${BW_ARGS[0]}" "arg 0"
    assert_eq "item" "${BW_ARGS[1]}" "arg 1"
    assert_eq "--" "${BW_ARGS[2]}" "arg separator"
    assert_eq "${VALID_UUID}" "${BW_ARGS[3]}" "item id"

    local bad_id
    for bad_id in "--help" "-x" "item-1" "../etc/passwd" "11111111-2222-3333-4444-55555555555g"; do
        invoke_script bw.item.get "${bad_id}"
        assert_eq "1" "${RC}" "reject non-UUID ${bad_id}"
        assert_contains "${STDERR}" "UUID" "stderr mentions UUID for ${bad_id}"
    done
}

test_item_get_arg_validation() {
    invoke_script bw.item.get
    assert_eq "1" "${RC}" "0 args"
    assert_contains "${STDERR}" "Usage:" "0 args usage"

    invoke_script bw.item.get ""
    assert_eq "1" "${RC}" "empty arg"
    assert_contains "${STDERR}" "Usage:" "empty arg usage"

    invoke_script bw.item.get "${VALID_UUID}" "extra"
    assert_eq "1" "${RC}" "extra args"
    assert_contains "${STDERR}" "Usage:" "extra args usage"
}

# --- bw.item.pass ---

test_item_pass_happy_and_uuid_validation() {
    printf 's3cr3t!\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.pass "${VALID_UUID_2}"
    read_bw_args
    assert_eq "0" "${RC}" "exit code"
    assert_eq "s3cr3t!" "${STDOUT}" "password stdout"
    assert_eq "get" "${BW_ARGS[0]}" "arg 0"
    assert_eq "password" "${BW_ARGS[1]}" "arg 1"
    assert_eq "--" "${BW_ARGS[2]}" "separator"
    assert_eq "${VALID_UUID_2}" "${BW_ARGS[3]}" "item id"

    local bad_id
    for bad_id in "--help" "-x" "item-2"; do
        invoke_script bw.item.pass "${bad_id}"
        assert_eq "1" "${RC}" "reject non-UUID ${bad_id}"
        assert_contains "${STDERR}" "UUID" "stderr mentions UUID for ${bad_id}"
    done
}

test_item_pass_arg_validation() {
    invoke_script bw.item.pass
    assert_eq "1" "${RC}" "0 args"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.pass ""
    assert_eq "1" "${RC}" "empty arg"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.pass "${VALID_UUID}" "${VALID_UUID_2}"
    assert_eq "1" "${RC}" "extra args"
    assert_contains "${STDERR}" "Usage:" "usage"
}

# --- bw.item.search ---

test_item_search_happy_and_special_chars() {
    local term="prod db * 'quoted' \$var"
    printf '[{"id":"%s","name":"%s","deletedDate":null}]\n' "${VALID_UUID}" "${term}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "${term}"
    read_bw_args
    assert_eq "0" "${RC}" "exit code"
    assert_eq "${VALID_UUID}" "${STDOUT}" "matched ID"
    assert_eq "list" "${BW_ARGS[0]}" "arg 0"
    assert_eq "items" "${BW_ARGS[1]}" "arg 1"
    assert_eq "--search=${term}" "${BW_ARGS[2]}" "search arg intact"

    local dash_arg
    for dash_arg in "--help" "-x"; do
        printf '[{"id":"%s","name":"%s"}]\n' "${VALID_UUID}" "${dash_arg}" > "${STATE_DIR}/bw_stdout"
        invoke_script bw.item.search "${dash_arg}"
        read_bw_args
        assert_eq "0" "${RC}" "exit code for ${dash_arg}"
        assert_eq "--search=${dash_arg}" "${BW_ARGS[2]}" "dash search safely attached to --search="
    done
}

test_item_search_rejects_fuzzy_and_soft_deleted() {
    # Fuzzy substring match must not match.
    printf '[{"id":"%s","name":"prod-extra","deletedDate":null}]\n' "${VALID_UUID}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "prod"
    assert_eq "2" "${RC}" "fuzzy match exits 2"

    # Soft-deleted item must not match.
    printf '[{"id":"%s","name":"prod","deletedDate":"2026-01-01T00:00:00Z"}]\n' "${VALID_UUID}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "prod"
    assert_eq "2" "${RC}" "soft-deleted item exits 2"

    # Exact active item matches even when fuzzy and soft-deleted items are present.
    printf '[{"id":"fuzzy-id","name":"prod-extra","deletedDate":null},{"id":"del-id","name":"prod","deletedDate":"2026-01-01T00:00:00Z"},{"id":"%s","name":"prod","deletedDate":null}]\n' "${VALID_UUID}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "prod"
    assert_eq "0" "${RC}" "exact active item matches"
    assert_eq "${VALID_UUID}" "${STDOUT}" "exact active item ID returned"
}

test_item_search_zero_and_multiple_matches() {
    printf '[]\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "missing"
    assert_eq "2" "${RC}" "0 matches exits 2"
    assert_contains "${STDERR}" "0 items" "stderr mentions 0 items"

    printf '[{"id":"a","name":"dup"},{"id":"b","name":"dup"}]\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "dup"
    assert_eq "3" "${RC}" "multiple matches exits 3"
    assert_contains "${STDERR}" "2 items" "stderr mentions count"
}

test_item_search_errors_and_invalid_json() {
    # Non-array JSON
    printf '{"a":1}\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "obj"
    assert_eq "1" "${RC}" "non-array JSON exits 1"

    # Malformed JSON
    printf '{broken\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.search "broken"
    assert_eq "1" "${RC}" "invalid JSON exits 1"

    # Missing, null, empty, and non-string .id
    local payload
    for payload in \
        '[{"name":"badid"}]' \
        '[{"id":null,"name":"badid"}]' \
        '[{"id":"","name":"badid"}]' \
        '[{"id":123,"name":"badid"}]'; do
        printf '%s\n' "${payload}" > "${STATE_DIR}/bw_stdout"
        invoke_script bw.item.search "badid"
        assert_eq "1" "${RC}" "bad ID payload ${payload} exits 1"
        assert_contains "${STDERR}" "no valid ID" "stderr mentions invalid ID"
    done

    # bw command fails
    printf '1\n' > "${STATE_DIR}/bw_exit"
    invoke_script bw.item.search "fail"
    assert_eq "1" "${RC}" "bw failure exits 1"
}

test_item_search_arg_validation() {
    invoke_script bw.item.search
    assert_eq "1" "${RC}" "0 args"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.search ""
    assert_eq "1" "${RC}" "empty arg"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.search "a" "b"
    assert_eq "1" "${RC}" "extra args"
    assert_contains "${STDERR}" "Usage:" "usage"
}

# --- bw.item.field ---

test_item_field_happy_null_empty_and_boolean_values() {
    printf '{"fields":[{"name":"user","value":"alice"},{"name":"empty","value":""},{"name":"nil","value":null},{"name":"flag_false","value":false},{"name":"flag_true","value":true},{"name":"zero","value":0}]}\n' > "${STATE_DIR}/bw_stdout"

    invoke_script bw.item.field "${VALID_UUID}" "user"
    assert_eq "0" "${RC}" "normal field exit code"
    assert_eq "alice" "${STDOUT}" "normal field value"

    invoke_script bw.item.field "${VALID_UUID}" "empty"
    assert_eq "0" "${RC}" "empty value exit code"
    assert_eq "" "${STDOUT}" "empty value returns empty string"

    invoke_script bw.item.field "${VALID_UUID}" "nil"
    assert_eq "0" "${RC}" "null value exit code"
    assert_eq "" "${STDOUT}" "null value returns empty string, not 'null'"

    invoke_script bw.item.field "${VALID_UUID}" "flag_false"
    assert_eq "0" "${RC}" "boolean false exit code"
    assert_eq "false" "${STDOUT}" "boolean false preserved as 'false'"

    invoke_script bw.item.field "${VALID_UUID}" "flag_true"
    assert_eq "0" "${RC}" "boolean true exit code"
    assert_eq "true" "${STDOUT}" "boolean true preserved as 'true'"

    invoke_script bw.item.field "${VALID_UUID}" "zero"
    assert_eq "0" "${RC}" "numeric zero exit code"
    assert_eq "0" "${STDOUT}" "numeric zero preserved as '0'"
}

test_item_field_missing_null_and_duplicate_fields() {
    # Missing .fields
    printf '{"id":"%s"}\n' "${VALID_UUID}" > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.field "${VALID_UUID}" "user"
    assert_eq "2" "${RC}" "missing .fields exits 2"

    # Null .fields
    printf '{"fields":null}\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.field "${VALID_UUID}" "user"
    assert_eq "2" "${RC}" "null .fields exits 2"

    # 0 matches
    printf '{"fields":[{"name":"other","value":"x"}]}\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.field "${VALID_UUID}" "user"
    assert_eq "2" "${RC}" "0 matching fields exits 2"

    # Duplicate fields
    printf '{"fields":[{"name":"dup","value":"1"},{"name":"dup","value":"2"}]}\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.field "${VALID_UUID}" "dup"
    assert_eq "3" "${RC}" "duplicate fields exits 3"
    assert_contains "${STDERR}" "fields" "stderr mentions fields"
}

test_item_field_preserves_bw_item_get_stderr() {
    printf '{"fields":[{"name":"k","value":"v"}]}\n' > "${STATE_DIR}/bw_stdout"
    printf 'bw warning from stderr\n' > "${STATE_DIR}/bw_stderr"

    invoke_script bw.item.field "${VALID_UUID}" "k"
    assert_eq "0" "${RC}" "exit code"
    assert_eq "v" "${STDOUT}" "field value"
    assert_contains "${STDERR}" "bw warning from stderr" "stderr from bw.item.get is not swallowed"

    printf '1\n' > "${STATE_DIR}/bw_exit"
    invoke_script bw.item.field "${VALID_UUID}" "k"
    assert_eq "1" "${RC}" "failure exit code"
    assert_contains "${STDERR}" "bw warning from stderr" "stderr preserved on failure"
}

test_item_field_invalid_json_and_arg_validation() {
    printf 'not-json\n' > "${STATE_DIR}/bw_stdout"
    invoke_script bw.item.field "${VALID_UUID}" "k"
    assert_eq "1" "${RC}" "invalid JSON exits 1"

    invoke_script bw.item.field "not-a-uuid" "k"
    assert_eq "1" "${RC}" "non-UUID itemID exits 1"
    assert_contains "${STDERR}" "UUID" "stderr mentions UUID"

    invoke_script bw.item.field
    assert_eq "1" "${RC}" "0 args"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.field "${VALID_UUID}"
    assert_eq "1" "${RC}" "1 arg"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.field "" "k"
    assert_eq "1" "${RC}" "empty itemID"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.field "${VALID_UUID}" ""
    assert_eq "1" "${RC}" "empty fieldName"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.field "${VALID_UUID}" "k" "extra"
    assert_eq "1" "${RC}" "3 args"
    assert_contains "${STDERR}" "Usage:" "usage"
}

# --- bw.item.attachmentID ---

test_attachment_id_exact_and_prefix_modes() {
    printf '{"attachments":[{"id":"att-1","fileName":"alpha.txt"},{"id":"att-2","fileName":"alpha.pub"},{"id":"att-3","fileName":"beta.txt"}]}\n' > "${STATE_DIR}/bw_stdout"

    # --exact match
    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "alpha.txt"
    assert_eq "0" "${RC}" "--exact match"
    assert_eq "att-1" "${STDOUT}" "matched attachment ID"

    # --exact 0 matches with default label
    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "none"
    assert_eq "2" "${RC}" "--exact 0 matches"
    assert_contains "${STDERR}" "Attachment matched 0 attachments" "default label"

    # --prefix >1 matches with default label
    invoke_script bw.item.attachmentID "${VALID_UUID}" --prefix "alpha"
    assert_eq "3" "${RC}" "--prefix >1 matches"
    assert_contains "${STDERR}" "Attachment matched 2 attachments" "default label for >1"

    # --prefix with --suffix
    invoke_script bw.item.attachmentID "${VALID_UUID}" --prefix "alpha" --suffix ".pub" --label "SSH cert"
    assert_eq "0" "${RC}" "--prefix + --suffix match"
    assert_eq "att-2" "${STDOUT}" "matched suffix ID"

    # --prefix with --exclude-suffix
    invoke_script bw.item.attachmentID "${VALID_UUID}" --prefix "alpha" --exclude-suffix ".pub" --label "Private key"
    assert_eq "0" "${RC}" "--prefix + --exclude-suffix match"
    assert_eq "att-1" "${STDOUT}" "matched exclude-suffix ID"

    # Custom label on 0 matches
    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "none" --label "SSH cert"
    assert_eq "2" "${RC}" "custom label 0 matches"
    assert_contains "${STDERR}" "SSH cert matched 0 attachments" "custom label message"
}

test_attachment_id_security_and_arg_validation() {
    printf '{"attachments":[{"id":"att-1","fileName":"a"}]}\n' > "${STATE_DIR}/bw_stdout"

    # Reject non-UUID itemID
    invoke_script bw.item.attachmentID "item-1" --exact "a"
    assert_eq "1" "${RC}" "non-UUID itemID exits 1"
    assert_contains "${STDERR}" "UUID" "stderr mentions UUID"

    # Reject raw jq filter / arbitrary flags / arithmetic injection attempts
    invoke_script bw.item.attachmentID "${VALID_UUID}" '.attachments[]?'
    assert_eq "1" "${RC}" "raw jq filter rejected"

    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "a" --arg x y
    assert_eq "1" "${RC}" "arbitrary --arg rejected"

    invoke_script bw.item.attachmentID "${VALID_UUID}" --slurpfile x /etc/passwd
    assert_eq "1" "${RC}" "arbitrary --slurpfile rejected"

    local pwn_file="${TEST_DIR}/pwned"
    invoke_script bw.item.attachmentID "${VALID_UUID}" "a[\$(touch ${pwn_file})]"
    assert_eq "1" "${RC}" "arithmetic injection rejected"
    if [[ -e "${pwn_file}" ]]; then
        echo "Assertion failed: command injection executed." >&2
        return 1
    fi

    # Conflicting options
    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "a" --prefix "a"
    assert_eq "1" "${RC}" "--exact and --prefix rejected"

    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "a" --suffix ".txt"
    assert_eq "1" "${RC}" "--exact and --suffix rejected"

    invoke_script bw.item.attachmentID "${VALID_UUID}" --prefix "a" --suffix ".pub" --exclude-suffix ".pub"
    assert_eq "1" "${RC}" "--suffix and --exclude-suffix rejected"

    # Missing, null, empty .id
    local payload
    for payload in \
        '{"attachments":[{"fileName":"a"}]}' \
        '{"attachments":[{"id":null,"fileName":"a"}]}' \
        '{"attachments":[{"id":"","fileName":"a"}]}'; do
        printf '%s\n' "${payload}" > "${STATE_DIR}/bw_stdout"
        invoke_script bw.item.attachmentID "${VALID_UUID}" --exact "a"
        assert_eq "1" "${RC}" "invalid ID payload ${payload} exits 1"
        assert_contains "${STDERR}" "no valid ID" "stderr mentions invalid ID"
    done

    # Arg validation
    invoke_script bw.item.attachmentID
    assert_eq "1" "${RC}" "0 args"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.attachmentID "${VALID_UUID}"
    assert_eq "1" "${RC}" "1 arg"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.attachmentID "" --exact "a"
    assert_eq "1" "${RC}" "empty itemID"
    assert_contains "${STDERR}" "Usage:" "usage"

    invoke_script bw.item.attachmentID "${VALID_UUID}" --exact ""
    assert_eq "1" "${RC}" "empty --exact value"
    assert_contains "${STDERR}" "Usage:" "usage"
}

# --- bw.item.privKeyID & bw.item.pubKeyID ---

test_priv_and_pub_key_id_happy_and_null_filenames() {
    printf '{"attachments":[{"id":"bad-null","fileName":null},{"id":"bad-missing"},{"id":"priv-1","fileName":"id_ed25519_prod"},{"id":"pub-1","fileName":"id_ed25519_prod.pub"},{"id":"other","fileName":"notes.txt"}]}\n' > "${STATE_DIR}/bw_stdout"

    invoke_script bw.item.privKeyID "${VALID_UUID}" "id_ed25519"
    assert_eq "0" "${RC}" "privKeyID exit code"
    assert_eq "priv-1" "${STDOUT}" "privKeyID matches prefix without .pub"

    invoke_script bw.item.pubKeyID "${VALID_UUID}" "id_ed25519"
    assert_eq "0" "${RC}" "pubKeyID exit code"
    assert_eq "pub-1" "${STDOUT}" "pubKeyID matches prefix with .pub"
}

test_priv_and_pub_key_id_zero_and_multiple_matches() {
    printf '{"attachments":[{"id":"a","fileName":"id_rsa_1"},{"id":"b","fileName":"id_rsa_2"},{"id":"c","fileName":"id_rsa_1.pub"},{"id":"d","fileName":"id_rsa_2.pub"}]}\n' > "${STATE_DIR}/bw_stdout"

    invoke_script bw.item.privKeyID "${VALID_UUID}" "id_ed25519"
    assert_eq "2" "${RC}" "privKeyID 0 matches"
    assert_contains "${STDERR}" "Private key matched 0 attachments" "privKeyID 0-match msg"

    invoke_script bw.item.privKeyID "${VALID_UUID}" "id_rsa"
    assert_eq "3" "${RC}" "privKeyID >1 matches"
    assert_contains "${STDERR}" "Private key matched 2 attachments" "privKeyID multi-match msg"

    invoke_script bw.item.pubKeyID "${VALID_UUID}" "id_ed25519"
    assert_eq "2" "${RC}" "pubKeyID 0 matches"
    assert_contains "${STDERR}" "Public key matched 0 attachments" "pubKeyID 0-match msg"

    invoke_script bw.item.pubKeyID "${VALID_UUID}" "id_rsa"
    assert_eq "3" "${RC}" "pubKeyID >1 matches"
    assert_contains "${STDERR}" "Public key matched 2 attachments" "pubKeyID multi-match msg"
}

test_priv_and_pub_key_id_arg_validation() {
    printf '{"attachments":[{"id":"any","fileName":"anything"},{"id":"anypub","fileName":"anything.pub"}]}\n' > "${STATE_DIR}/bw_stdout"

    local script
    for script in bw.item.privKeyID bw.item.pubKeyID; do
        invoke_script "${script}"
        assert_eq "1" "${RC}" "${script} 0 args"
        assert_contains "${STDERR}" "Usage:" "${script} 0 args usage"

        invoke_script "${script}" "${VALID_UUID}"
        assert_eq "1" "${RC}" "${script} 1 arg"
        assert_contains "${STDERR}" "Usage:" "${script} 1 arg usage"

        invoke_script "${script}" "${VALID_UUID}" ""
        assert_eq "1" "${RC}" "${script} empty prefix"
        assert_contains "${STDERR}" "Usage:" "${script} empty prefix usage"

        invoke_script "${script}" "" "id_ed25519"
        assert_eq "1" "${RC}" "${script} empty itemID"
        assert_contains "${STDERR}" "Usage:" "${script} empty itemID usage"

        invoke_script "${script}" "not-a-uuid" "id_ed25519"
        assert_eq "1" "${RC}" "${script} non-UUID itemID"
        assert_contains "${STDERR}" "UUID" "${script} non-UUID stderr"

        invoke_script "${script}" "${VALID_UUID}" "id_ed25519" "extra"
        assert_eq "1" "${RC}" "${script} 3 args"
        assert_contains "${STDERR}" "Usage:" "${script} 3 args usage"
    done
}

run_case "bw.item.get happy path and UUID validation" test_item_get_happy_and_uuid_validation
run_case "bw.item.get rejects invalid arg counts and empty args" test_item_get_arg_validation
run_case "bw.item.pass happy path and UUID validation" test_item_pass_happy_and_uuid_validation
run_case "bw.item.pass rejects invalid arg counts and empty args" test_item_pass_arg_validation
run_case "bw.item.search happy path, special chars, and leading-dash terms" test_item_search_happy_and_special_chars
run_case "bw.item.search rejects fuzzy substring matches and soft-deleted items" test_item_search_rejects_fuzzy_and_soft_deleted
run_case "bw.item.search exit codes for 0 and >1 matches" test_item_search_zero_and_multiple_matches
run_case "bw.item.search rejects non-array, invalid JSON, and bad IDs" test_item_search_errors_and_invalid_json
run_case "bw.item.search rejects invalid arg counts and empty args" test_item_search_arg_validation
run_case "bw.item.field happy path, null, empty, and boolean values" test_item_field_happy_null_empty_and_boolean_values
run_case "bw.item.field missing/null .fields, 0 matches, and duplicate fields" test_item_field_missing_null_and_duplicate_fields
run_case "bw.item.field forwards stderr from bw.item.get" test_item_field_preserves_bw_item_get_stderr
run_case "bw.item.field invalid JSON, non-UUID, and arg validation" test_item_field_invalid_json_and_arg_validation
run_case "bw.item.attachmentID supports --exact, --prefix, --suffix, --exclude-suffix, and --label" test_attachment_id_exact_and_prefix_modes
run_case "bw.item.attachmentID rejects arbitrary flags, non-UUIDs, injection, and bad IDs" test_attachment_id_security_and_arg_validation
run_case "bw.item.privKeyID and pubKeyID handle valid keys and null/missing fileName" test_priv_and_pub_key_id_happy_and_null_filenames
run_case "bw.item.privKeyID and pubKeyID exit 2 on 0 matches and 3 on >1 matches" test_priv_and_pub_key_id_zero_and_multiple_matches
run_case "bw.item.privKeyID and pubKeyID reject invalid arg counts, non-UUIDs, and empty prefix" test_priv_and_pub_key_id_arg_validation

echo "test_bw_items.sh: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ "${FAIL_COUNT}" -eq 0 ]]
