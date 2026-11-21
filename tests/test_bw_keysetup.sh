#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW_KEYSETUP="${REPO_DIR}/bw.keysetup"

PASS_COUNT=0
FAIL_COUNT=0

TEST_ROOT="$(mktemp -d)"
RUNTIME_ROOT="$(mktemp -d -p /dev/shm bw_keysetup_test_rt.XXXXXXXXXX)"
cleanup_root() {
  if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
    chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
    rm -rf -- "${TEST_ROOT}"
  fi
  if [[ -n "${RUNTIME_ROOT}" && -d "${RUNTIME_ROOT}" ]]; then
    chmod -R u+rwx -- "${RUNTIME_ROOT}" 2>/dev/null || true
    rm -rf -- "${RUNTIME_ROOT}"
  fi
}
trap cleanup_root EXIT

fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    fail_msg "${label}: expected '${expected}', got '${actual}'."
    return 1
  fi
}

assert_ne() {
  local unexpected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${unexpected}" == "${actual}" ]]; then
    fail_msg "${label}: unexpected value '${actual}'."
    return 1
  fi
}

assert_ge() {
  local actual="$1"
  local min_val="$2"
  local label="$3"
  if [[ "${actual}" -lt "${min_val}" ]]; then
    fail_msg "${label}: expected >= ${min_val}, got ${actual}."
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail_msg "${label}: output lacks '${needle}'."
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    fail_msg "${label}: output must not contain '${needle}'."
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ ! -e "${path}" ]]; then
    fail_msg "${label}: missing path: ${path}."
    return 1
  fi
}

assert_file_not_exists() {
  local path="$1"
  local label="$2"
  if [[ -e "${path}" ]]; then
    fail_msg "${label}: path still exists: ${path}."
    return 1
  fi
}

assert_dir_empty() {
  local dir="$1"
  local label="$2"
  local leftover
  leftover="$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
  if [[ -n "${leftover}" ]]; then
    fail_msg "${label}: directory is not empty: ${leftover}."
    return 1
  fi
}

count_pattern() {
  local file="$1"
  local pattern="$2"
  if [[ ! -f "${file}" ]]; then
    printf '0\n'
    return 0
  fi
  grep -Ec "${pattern}" "${file}" || true
}

# Create an isolated vault, mock PATH, tmpfs runtime dir, and fake remote filesystem.
setup_case() {
  local name="$1"
  local sshd_mode="${2:-dropin}"

  CASE_DIR="${TEST_ROOT}/${name}"
  MOCK_BIN="${CASE_DIR}/bin"
  FAKE_REMOTE_BIN="${CASE_DIR}/remote_bin"
  FAKE_ROOT="${CASE_DIR}/fake_root"
  VAULT_DIR="${CASE_DIR}/vault"
  RUNTIME_DIR="${RUNTIME_ROOT}/${name}"
  STATE_DIR="${CASE_DIR}/state"

  mkdir -p \
    "${MOCK_BIN}" \
    "${FAKE_REMOTE_BIN}" \
    "${FAKE_ROOT}/etc/ssh" \
    "${FAKE_ROOT}/root" \
    "${FAKE_ROOT}/home" \
    "${VAULT_DIR}/items" \
    "${VAULT_DIR}/attachments" \
    "${RUNTIME_DIR}" \
    "${STATE_DIR}"
  chmod 700 "${RUNTIME_DIR}"

  printf '0\n' > "${VAULT_DIR}/item.seq"
  printf '0\n' > "${VAULT_DIR}/att.seq"
  printf '0\n' > "${VAULT_DIR}/gen.seq"

  printf 'root:x:0:0:root:%s/root:/bin/bash\n' "${FAKE_ROOT}" > "${FAKE_ROOT}/etc/passwd"
  printf 'root:!:19000:0:99999:7:::\n' > "${FAKE_ROOT}/etc/shadow"
  chmod 640 "${FAKE_ROOT}/etc/shadow"

  if [[ "${sshd_mode}" == "dropin" ]]; then
    mkdir -p "${FAKE_ROOT}/etc/ssh/sshd_config.d"
    cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Port 22
PermitRootLogin yes
EOF
  else
    cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Port 22
# PermitRootLogin yes
PasswordAuthentication yes

Match User admin
    PermitRootLogin yes
EOF
  fi

  # Mock bw.sess.
  cat > "${MOCK_BIN}/bw.sess" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_SESS_RC:-0}"
EOF

  # Stateful mock bw CLI emitting valid UUIDs.
  cat > "${MOCK_BIN}/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "${cmd}" in
  generate)
    printf 'generate %s\n' "$*" >> "${STATE_DIR}/bw_ops.log"
    if [[ "${MOCK_GEN_RC:-0}" -ne 0 ]]; then
      exit "${MOCK_GEN_RC}"
    fi
    length=32
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --length)
          length="${2:-32}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    seq_num="$(cat "${VAULT_DIR}/gen.seq")"
    seq_num=$((seq_num + 1))
    printf '%s\n' "${seq_num}" > "${VAULT_DIR}/gen.seq"
    base="$(printf 'Gen%04dAbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGhIjKlMnOp' "${seq_num}")"
    printf '%s\n' "${base:0:${length}}"
    ;;
  get)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      template)
        tname="${1:-}"
        if [[ "${tname}" == "item" ]]; then
          printf '{"type":1,"name":"","notes":null,"login":null,"fields":[]}\n'
        elif [[ "${tname}" == "item.login" ]]; then
          printf '{"username":null,"password":null,"totp":null}\n'
        else
          exit 1
        fi
        ;;
      attachment)
        att_id="${1:-}"
        shift || true
        item_id=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --itemid)
              item_id="${2:-}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        cat "${VAULT_DIR}/attachments/${item_id}/${att_id}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  encode)
    base64 -w0
    ;;
  create)
    sub="${1:-}"
    shift || true
    case "${sub}" in
      item)
        printf 'create item\n' >> "${STATE_DIR}/bw_ops.log"
        raw_json="$(base64 -d)"
        seq_num="$(cat "${VAULT_DIR}/item.seq")"
        seq_num=$((seq_num + 1))
        printf '%s\n' "${seq_num}" > "${VAULT_DIR}/item.seq"
        item_id="$(printf '00000000-0000-4000-8000-%012d' "${seq_num}")"
        stored="$(printf '%s\n' "${raw_json}" | jq --arg id "${item_id}" '.id = $id | .attachments = (.attachments // [])')"
        printf '%s\n' "${stored}" > "${VAULT_DIR}/items/${item_id}.json"
        printf '%s\n' "${stored}"
        ;;
      attachment)
        item_id=""
        file_path=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --itemid)
              item_id="${2:-}"
              shift 2
              ;;
            --file)
              file_path="${2:-}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        base_name="$(basename "${file_path}")"
        printf 'create attachment %s %s\n' "${item_id}" "${base_name}" >> "${STATE_DIR}/bw_ops.log"
        if [[ "${MOCK_ATTACH_PRIV_RC:-0}" -ne 0 && "${base_name}" != *.pub ]]; then
          exit "${MOCK_ATTACH_PRIV_RC}"
        fi
        if [[ "${MOCK_ATTACH_PUB_RC:-0}" -ne 0 && "${base_name}" == *.pub ]]; then
          exit "${MOCK_ATTACH_PUB_RC}"
        fi
        seq_num="$(cat "${VAULT_DIR}/att.seq")"
        seq_num=$((seq_num + 1))
        printf '%s\n' "${seq_num}" > "${VAULT_DIR}/att.seq"
        att_id="$(printf 'aaaaaaaa-aaaa-4aaa-8aaa-%012d' "${seq_num}")"
        mkdir -p "${VAULT_DIR}/attachments/${item_id}"
        cp "${file_path}" "${VAULT_DIR}/attachments/${item_id}/${att_id}"
        tmp_item="${VAULT_DIR}/items/${item_id}.json.tmp"
        jq --arg aid "${att_id}" --arg fn "${base_name}" \
          '.attachments = ((.attachments // []) + [{id: $aid, fileName: $fn}])' \
          "${VAULT_DIR}/items/${item_id}.json" > "${tmp_item}"
        mv "${tmp_item}" "${VAULT_DIR}/items/${item_id}.json"
        cat "${VAULT_DIR}/items/${item_id}.json"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  edit)
    sub="${1:-}"
    item_id="${2:-}"
    if [[ "${sub}" != "item" || -z "${item_id}" ]]; then
      exit 1
    fi
    printf 'edit item %s\n' "${item_id}" >> "${STATE_DIR}/bw_ops.log"
    raw_json="$(base64 -d)"
    printf '%s\n' "${raw_json}" > "${VAULT_DIR}/items/${item_id}.json"
    printf '%s\n' "${raw_json}"
    ;;
  sync)
    printf 'sync\n' >> "${STATE_DIR}/bw_ops.log"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF

  # Stateful mock bw.item.search.
  cat > "${MOCK_BIN}/bw.item.search" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${1:-}"
if [[ "${MOCK_SEARCH_RC:-0}" -ne 0 ]]; then
  if [[ -z "${MOCK_SEARCH_QUERY:-}" || "${MOCK_SEARCH_QUERY}" == "${query}" ]]; then
    exit "${MOCK_SEARCH_RC}"
  fi
fi
if [[ -n "${MOCK_SEARCH_RETURN_ID:-}" ]]; then
  printf '%s\n' "${MOCK_SEARCH_RETURN_ID}"
  exit 0
fi

matches=()
shopt -s nullglob
for f in "${VAULT_DIR}/items/"*.json; do
  name="$(jq -r '.name // empty' "${f}")"
  if [[ "${name}" == "${query}" ]]; then
    matches+=("$(jq -r '.id' "${f}")")
  fi
done
shopt -u nullglob

if [[ "${#matches[@]}" -eq 0 ]]; then
  exit 2
elif [[ "${#matches[@]}" -gt 1 ]]; then
  exit 3
fi
printf '%s\n' "${matches[0]}"
EOF

  # Stateful mock bw.item.get.
  cat > "${MOCK_BIN}/bw.item.get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
item_id="${1:-}"
cat "${VAULT_DIR}/items/${item_id}.json"
EOF

  # Stateful mock bw.item.pass.
  cat > "${MOCK_BIN}/bw.item.pass" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_PASS_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_PASS_RC}"
fi
item_id="${1:-}"
pw="$(jq -r '.login.password // empty' "${VAULT_DIR}/items/${item_id}.json")"
if [[ -z "${pw}" ]]; then
  exit 2
fi
printf '%s\n' "${pw}"
EOF

  # Stateful mock bw.item.field.
  cat > "${MOCK_BIN}/bw.item.field" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_FIELD_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_FIELD_RC}"
fi
item_id="${1:-}"
field_name="${2:-}"
val="$(jq -r --arg n "${field_name}" '(.fields // []) | map(select(.name == $n)) | .[0].value // empty' "${VAULT_DIR}/items/${item_id}.json")"
if [[ -z "${val}" ]]; then
  exit 2
fi
printf '%s\n' "${val}"
EOF

  # Stateful mock bw.item.privKeyID.
  cat > "${MOCK_BIN}/bw.item.privKeyID" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_PRIVKEY_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_PRIVKEY_RC}"
fi
item_id="${1:-}"
query="${2:-}"
mapfile -t ids < <(jq -r --arg fn "${query}" '(.attachments // []) | map(select(.fileName == $fn)) | .[].id' "${VAULT_DIR}/items/${item_id}.json")
if [[ "${#ids[@]}" -eq 0 ]]; then
  exit 2
elif [[ "${#ids[@]}" -gt 1 ]]; then
  exit 3
fi
printf '%s\n' "${ids[0]}"
EOF

  # Stateful mock bw.item.pubKeyID.
  cat > "${MOCK_BIN}/bw.item.pubKeyID" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
item_id="${1:-}"
query="${2:-}"
mapfile -t ids < <(jq -r --arg fn "${query}.pub" '(.attachments // []) | map(select(.fileName == $fn)) | .[].id' "${VAULT_DIR}/items/${item_id}.json")
if [[ "${#ids[@]}" -eq 0 ]]; then
  exit 2
elif [[ "${#ids[@]}" -gt 1 ]]; then
  exit 3
fi
printf '%s\n' "${ids[0]}"
EOF

  # Stateful mock ssh executing remote scripts against FAKE_ROOT.
  cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-G" ]]; then
  if [[ "${MOCK_SSH_G_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_SSH_G_RC}"
  fi
  if [[ -n "${MOCK_SSH_G_OUT+x}" ]]; then
    printf '%s\n' "${MOCK_SSH_G_OUT}"
  else
    printf 'user root\nhost prod01.example.com\nhostname 10.0.0.20\n'
  fi
  exit 0
fi

opts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|-o|-i|-J|-l|-F|-c|-b|-L|-R|-D|-W|-S|-E)
      opts+=("$1" "${2:-}")
      shift 2
      ;;
    -*)
      opts+=("$1")
      shift
      ;;
    *)
      break
      ;;
  esac
done

dest="${1:-}"
shift || true
printf 'OPTS=[%s] DEST=[%s]\n' "${opts[*]-}" "${dest}" >> "${STATE_DIR}/ssh_calls.log"

if [[ "${1:-}" == "/usr/bin/env" && "${2:-}" == "bash" ]]; then
  script="$(cat)"
  script="${script//\"\/etc\/ssh\//\"${FAKE_ROOT}\/etc\/ssh\/}"
  script="${script//-p \/etc\/ssh /-p ${FAKE_ROOT}\/etc\/ssh }"
  PATH="${FAKE_REMOTE_BIN}:/usr/bin:/bin" \
    FAKE_ROOT="${FAKE_ROOT}" \
    STATE_DIR="${STATE_DIR}" \
    /usr/bin/env bash <<< "${script}"
else
  remote_cmd="$*"
  remote_cmd="${remote_cmd//\/etc\/shadow/${FAKE_ROOT}\/etc\/shadow}"
  remote_cmd="${remote_cmd//-p \/etc /-p ${FAKE_ROOT}\/etc }"
  remote_cmd="${remote_cmd//\"\/etc\/ssh\//\"${FAKE_ROOT}\/etc\/ssh\/}"
  PATH="${FAKE_REMOTE_BIN}:/usr/bin:/bin" \
    FAKE_ROOT="${FAKE_ROOT}" \
    STATE_DIR="${STATE_DIR}" \
    bash -c "${remote_cmd}"
fi
EOF

  # Fake remote utilities under FAKE_REMOTE_BIN.
  cat > "${FAKE_REMOTE_BIN}/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
db="${1:-}"
key="${2:-}"
case "${db}" in
  shadow)
    awk -F: -v u="${key}" '$1 == u { print; found = 1 } END { exit !found }' "${FAKE_ROOT}/etc/shadow"
    ;;
  passwd)
    awk -F: -v u="${key}" '$1 == u { print; found = 1 } END { exit !found }' "${FAKE_ROOT}/etc/passwd"
    ;;
  *)
    exit 2
    ;;
esac
EOF

  cat > "${FAKE_REMOTE_BIN}/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
flag="${1:-}"
target="${2:-}"
case "${flag}" in
  -u)
    awk -F: -v u="${target}" '$1 == u { print $3; found = 1 } END { exit !found }' "${FAKE_ROOT}/etc/passwd"
    ;;
  -gn)
    awk -F: -v u="${target}" '$1 == u { print $1; found = 1 } END { exit !found }' "${FAKE_ROOT}/etc/passwd"
    ;;
  *)
    exit 1
    ;;
esac
EOF

  cat > "${FAKE_REMOTE_BIN}/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'runuser %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF

  cat > "${FAKE_REMOTE_BIN}/useradd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "${STATE_DIR}/useradd.argv0"
printf 'useradd %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"

create_home=0
comment=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      create_home=1
      shift
      ;;
    -c)
      comment="${2:-}"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      break
      ;;
  esac
done

username="${1:-}"
home_dir="${FAKE_ROOT}/home/${username}"
cur_uid="$(/usr/bin/id -u)"
cur_gid="$(/usr/bin/id -g)"
printf '%s:x:%s:%s:%s:%s:/bin/bash\n' "${username}" "${cur_uid}" "${cur_gid}" "${comment}" "${home_dir}" >> "${FAKE_ROOT}/etc/passwd"
printf '%s:!:19000:0:99999:7:::\n' "${username}" >> "${FAKE_ROOT}/etc/shadow"
if [[ "${create_home}" -eq 1 ]]; then
  mkdir -p "${home_dir}"
fi
EOF

  cat > "${FAKE_REMOTE_BIN}/chpasswd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'chpasswd %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
if [[ "${MOCK_CHPASSWD_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_CHPASSWD_RC}"
fi
IFS= read -r line
target_user="${line%%:*}"
new_hash="${line#*:}"
if [[ "${MOCK_CHPASSWD_CORRUPT:-0}" -eq 1 ]]; then
  new_hash='$y$j9T$corrupted$wronghash'
fi

tmp_shadow="${FAKE_ROOT}/etc/shadow.chpasswd.tmp"
awk -F: -v OFS=: -v u="${target_user}" -v h="${new_hash}" '
  $1 == u { $2 = h }
  { print }
' "${FAKE_ROOT}/etc/shadow" > "${tmp_shadow}"
cat "${tmp_shadow}" > "${FAKE_ROOT}/etc/shadow"
rm -f "${tmp_shadow}"
EOF

  cat > "${FAKE_REMOTE_BIN}/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
exit 0
EOF

  cat > "${FAKE_REMOTE_BIN}/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
if [[ "${1:-}" == "-t" ]]; then
  exit "${MOCK_SSHD_T_RC:-0}"
elif [[ "${1:-}" == "-T" ]]; then
  if [[ "${MOCK_SSHD_CAP_T_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_SSHD_CAP_T_RC}"
  fi
  printf 'permitrootlogin %s\n' "${MOCK_EFFECTIVE_ROOT_LOGIN:-prohibit-password}"
  printf 'pubkeyauthentication %s\n' "${MOCK_EFFECTIVE_PUBKEY:-yes}"
  exit 0
fi
exit 0
EOF

  cat > "${FAKE_REMOTE_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${STATE_DIR}/systemctl.log"
if [[ "${1:-}" == "list-unit-files" ]]; then
  unit="${2:-}"
  if [[ "${unit}" == "${MOCK_SSH_UNIT:-ssh.service}" ]]; then
    printf '%s enabled\n' "${unit}"
  fi
fi
exit 0
EOF

  chmod +x \
    "${MOCK_BIN}/bw.sess" \
    "${MOCK_BIN}/bw" \
    "${MOCK_BIN}/bw.item.search" \
    "${MOCK_BIN}/bw.item.get" \
    "${MOCK_BIN}/bw.item.pass" \
    "${MOCK_BIN}/bw.item.field" \
    "${MOCK_BIN}/bw.item.privKeyID" \
    "${MOCK_BIN}/bw.item.pubKeyID" \
    "${MOCK_BIN}/ssh" \
    "${FAKE_REMOTE_BIN}/getent" \
    "${FAKE_REMOTE_BIN}/id" \
    "${FAKE_REMOTE_BIN}/runuser" \
    "${FAKE_REMOTE_BIN}/useradd" \
    "${FAKE_REMOTE_BIN}/chpasswd" \
    "${FAKE_REMOTE_BIN}/chown" \
    "${FAKE_REMOTE_BIN}/sshd" \
    "${FAKE_REMOTE_BIN}/systemctl"
}

run_bw_keysetup() {
  local out_file="${STATE_DIR}/stdout"
  local err_file="${STATE_DIR}/stderr"
  RUN_RC=0
  PATH="${MOCK_BIN}:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="${CUSTOM_RUNTIME_DIR-${RUNTIME_DIR}}" \
    VAULT_DIR="${VAULT_DIR}" \
    FAKE_ROOT="${FAKE_ROOT}" \
    FAKE_REMOTE_BIN="${FAKE_REMOTE_BIN}" \
    STATE_DIR="${STATE_DIR}" \
    "${BW_KEYSETUP}" "$@" >"${out_file}" 2>"${err_file}" || RUN_RC=$?
  RUN_STDOUT="$(cat "${out_file}")"
  RUN_STDERR="$(cat "${err_file}")"
}

seed_vault_item() {
  local item_id="$1"
  local json="$2"
  printf '%s\n' "${json}" > "${VAULT_DIR}/items/${item_id}.json"
}

find_vault_item_file() {
  local name="$1"
  local f
  shopt -s nullglob
  for f in "${VAULT_DIR}/items/"*.json; do
    if [[ "$(jq -r '.name // empty' "${f}")" == "${name}" ]]; then
      printf '%s\n' "${f}"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

compute_yescrypt() {
  local pw="$1"
  local salt="$2"
  printf '%s\0%s\0' "${pw}" "\$y\$j9T\$${salt}\$" | perl -e '
    local $/ = "\0";
    my $p = <STDIN>; my $s = <STDIN>;
    chomp($p); chomp($s);
    print crypt($p, $s);
  '
}

run_test() {
  local name="$1"
  local rc=0
  printf 'Running %s...\n' "${name}"
  set +e
  (
    set -euo pipefail
    "${name}"
  )
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Happy paths ---

test_happy_fresh_host_dropin_mode() {
  setup_case "happy_fresh_dropin" "dropin"
  run_bw_keysetup -p 2222 -o StrictHostKeyChecking=no root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "exit code"

  local root_item jumper_item
  root_item="$(find_vault_item_file "root@prod01.example.com")"
  jumper_item="$(find_vault_item_file "jumper@prod01.example.com")"
  assert_file_exists "${root_item}" "root vault item created"
  assert_file_exists "${jumper_item}" "jumper vault item created"

  # Verify JSON schema and secret lengths for both items.
  local item_file pw salt expected_hash actual_hash user_name
  for item_file in "${root_item}" "${jumper_item}"; do
    user_name="$(jq -r '.login.username' "${item_file}")"
    assert_eq "object" "$(jq -r '.login | type' "${item_file}")" "${user_name} .login is object"
    pw="$(jq -r '.login.password' "${item_file}")"
    salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${item_file}")"
    assert_ge "${#pw}" 32 "${user_name} password length >= 32"
    assert_ge "${#salt}" 32 "${user_name} salt length >= 32"

    # Stdout must never leak cleartext secrets or raw item JSON.
    assert_not_contains "${RUN_STDOUT}" "${pw}" "stdout does not leak ${user_name} password"
    assert_not_contains "${RUN_STDOUT}" "${salt}" "stdout does not leak ${user_name} salt"
    assert_not_contains "${RUN_STDOUT}" '"password_salt"' "stdout does not leak raw item JSON"

    expected_hash="$(compute_yescrypt "${pw}" "${salt}")"
    actual_hash="$(awk -F: -v u="${user_name}" '$1 == u { print $2 }' "${FAKE_ROOT}/etc/shadow")"
    assert_contains "${actual_hash}" "\$y\$j9T\$" "${user_name} shadow has Yescrypt prefix"
    assert_eq "${expected_hash}" "${actual_hash}" "${user_name} shadow hash matches perl crypt"
  done

  # Verify useradd received proper quoting for jumper user.
  local -a useradd_args=()
  mapfile -d '' -t useradd_args < "${STATE_DIR}/useradd.argv0"
  assert_eq "4" "${#useradd_args[@]}" "useradd arg count"
  assert_eq "-m" "${useradd_args[0]}" "useradd -m"
  assert_eq "-c" "${useradd_args[1]}" "useradd -c"
  assert_eq "jumper user" "${useradd_args[2]}" "useradd comment preserves space"
  assert_eq "jumper" "${useradd_args[3]}" "useradd username"

  # Verify runuser was used for non-root jumper key installation.
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "runuser -u jumper" "dropped privileges via runuser for jumper"

  # Verify ed25519 keys uploaded and installed into each user's own authorized_keys.
  local root_id jumper_id root_pub_id jumper_pub_id root_pub jumper_pub
  root_id="$(jq -r '.id' "${root_item}")"
  jumper_id="$(jq -r '.id' "${jumper_item}")"
  root_pub_id="$(jq -r '.attachments[] | select(.fileName == "root@prod01.example.com.pub") | .id' "${root_item}")"
  jumper_pub_id="$(jq -r '.attachments[] | select(.fileName == "jumper@prod01.example.com.pub") | .id' "${jumper_item}")"
  assert_ne "" "${root_pub_id}" "root .pub uploaded"
  assert_ne "" "${jumper_pub_id}" "jumper .pub uploaded"
  assert_ne "" "$(jq -r '.attachments[] | select(.fileName == "root@prod01.example.com") | .id' "${root_item}")" "root privkey uploaded"
  assert_ne "" "$(jq -r '.attachments[] | select(.fileName == "jumper@prod01.example.com") | .id' "${jumper_item}")" "jumper privkey uploaded"

  root_pub="$(cat "${VAULT_DIR}/attachments/${root_id}/${root_pub_id}")"
  jumper_pub="$(cat "${VAULT_DIR}/attachments/${jumper_id}/${jumper_pub_id}")"
  assert_contains "${root_pub}" "ssh-ed25519 " "root key is ed25519"
  assert_contains "${jumper_pub}" "ssh-ed25519 " "jumper key is ed25519"

  local root_ak jumper_ak
  root_ak="$(cat "${FAKE_ROOT}/root/.ssh/authorized_keys")"
  jumper_ak="$(cat "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys")"
  assert_contains "${root_ak}" "${root_pub}" "root authorized_keys contains root key"
  assert_not_contains "${root_ak}" "${jumper_pub}" "root authorized_keys does not contain jumper key"
  assert_contains "${jumper_ak}" "${jumper_pub}" "jumper authorized_keys contains jumper key"
  assert_not_contains "${jumper_ak}" "${root_pub}" "jumper authorized_keys does not contain root key"

  # Verify zero leftover temp directories in XDG_RUNTIME_DIR.
  assert_dir_empty "${RUNTIME_DIR}" "XDG_RUNTIME_DIR has no leftover temp dirs"

  # Verify custom SSH options forwarded to every remote ssh call.
  local total_ssh_calls matching_ssh_calls
  total_ssh_calls="$(wc -l < "${STATE_DIR}/ssh_calls.log")"
  matching_ssh_calls="$(count_pattern "${STATE_DIR}/ssh_calls.log" 'OPTS=\[-p 2222 -o StrictHostKeyChecking=no\]')"
  assert_ge "${total_ssh_calls}" 6 "at least 6 remote ssh calls"
  assert_eq "${total_ssh_calls}" "${matching_ssh_calls}" "every ssh call forwards custom options"

  # Verify sshd drop-in configuration, effective check, and service reload.
  assert_eq "PermitRootLogin prohibit-password" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf")" "sshd drop-in written"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "sshd -T -C user=root,host=localhost,addr=127.0.0.1" "verified effective sshd config"
  assert_contains "$(cat "${STATE_DIR}/systemctl.log")" "systemctl reload-or-restart ssh.service" "systemctl reloaded ssh.service"
}

test_happy_direct_sshd_config_edit_mode() {
  setup_case "happy_direct_sshd" "direct"
  run_bw_keysetup root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.bak" "sshd_config backup removed"

  local cfg match_line global_line
  cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  assert_contains "${cfg}" "PermitRootLogin prohibit-password" "PermitRootLogin set globally"
  assert_not_contains "${cfg}" "# PermitRootLogin yes" "commented directive replaced"
  assert_contains "${cfg}" "Match User admin" "Match block preserved"
  assert_contains "${cfg}" "    PermitRootLogin yes" "Match block directive preserved"

  global_line="$(grep -n '^PermitRootLogin prohibit-password$' "${FAKE_ROOT}/etc/ssh/sshd_config" | cut -d: -f1)"
  match_line="$(grep -n '^Match User admin$' "${FAKE_ROOT}/etc/ssh/sshd_config" | cut -d: -f1)"
  if [[ "${global_line}" -ge "${match_line}" ]]; then
    fail_msg "global PermitRootLogin must appear before Match block."
    return 1
  fi
}

test_happy_idempotent_rerun() {
  setup_case "happy_idempotent" "dropin"
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "first run succeeds"

  # Remove authorized_keys to verify rerun still installs remote keys.
  rm -f "${FAKE_ROOT}/root/.ssh/authorized_keys" "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys"
  : > "${STATE_DIR}/bw_ops.log"
  : > "${STATE_DIR}/remote_ops.log"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "second run succeeds"

  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no redundant item creation"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^edit item')" "no redundant item edits"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create attachment')" "no redundant key generation"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/remote_ops.log" '^chpasswd')" "no redundant chpasswd calls"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/remote_ops.log" '^useradd')" "no redundant useradd calls"
  assert_file_exists "${FAKE_ROOT}/root/.ssh/authorized_keys" "root authorized_keys restored"
  assert_file_exists "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys" "jumper authorized_keys restored"
}

# --- Security regression tests ---

test_security_jumper_symlink_attack_rejected() {
  # Symlink authorized_keys -> /root/.ssh/authorized_keys.
  setup_case "security_symlink_authkeys" "dropin"
  local cur_uid cur_gid
  cur_uid="$(/usr/bin/id -u)"
  cur_gid="$(/usr/bin/id -g)"
  printf 'jumper:x:%s:%s:jumper user:%s/home/jumper:/bin/bash\n' "${cur_uid}" "${cur_gid}" "${FAKE_ROOT}" >> "${FAKE_ROOT}/etc/passwd"
  printf 'jumper:!:19000:0:99999:7:::\n' >> "${FAKE_ROOT}/etc/shadow"
  mkdir -p "${FAKE_ROOT}/home/jumper/.ssh"
  ln -s "${FAKE_ROOT}/root/.ssh/authorized_keys" "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys"

  run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "symlink authorized_keys attack fails"
  assert_contains "${RUN_STDERR}" "authorized_keys is a symlink" "stderr reports symlink authorized_keys"
  assert_not_contains "$(cat "${FAKE_ROOT}/root/.ssh/authorized_keys")" "jumper@prod01.example.com" "root authorized_keys not modified by jumper"

  # Symlink .ssh -> /root/.ssh.
  setup_case "security_symlink_sshdir" "dropin"
  printf 'jumper:x:%s:%s:jumper user:%s/home/jumper:/bin/bash\n' "${cur_uid}" "${cur_gid}" "${FAKE_ROOT}" >> "${FAKE_ROOT}/etc/passwd"
  printf 'jumper:!:19000:0:99999:7:::\n' >> "${FAKE_ROOT}/etc/shadow"
  mkdir -p "${FAKE_ROOT}/home/jumper"
  ln -s "${FAKE_ROOT}/root/.ssh" "${FAKE_ROOT}/home/jumper/.ssh"

  run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "symlink .ssh dir attack fails"
  assert_contains "${RUN_STDERR}" "SSH directory is a symlink" "stderr reports symlink .ssh dir"
  assert_not_contains "$(cat "${FAKE_ROOT}/root/.ssh/authorized_keys")" "jumper@prod01.example.com" "root authorized_keys untouched"
}

test_security_malicious_pubkey_rejected_before_ssh() {
  local item_uuid="10000000-0000-4000-8000-000000000090"
  local priv_uuid="aaaaaaaa-aaaa-4aaa-8aaa-000000000091"
  local pub_uuid="aaaaaaaa-aaaa-4aaa-8aaa-000000000092"
  local mode

  for mode in option_injection embedded_newline bad_crypto; do
    setup_case "security_bad_pubkey_${mode}" "dropin"
    seed_vault_item "${item_uuid}" "{
      \"id\": \"${item_uuid}\",
      \"type\": 1,
      \"name\": \"root@prod01.example.com\",
      \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
      \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt1234567890123456789012345678\", \"type\": 0}],
      \"attachments\": [
        {\"id\": \"${priv_uuid}\", \"fileName\": \"root@prod01.example.com\"},
        {\"id\": \"${pub_uuid}\", \"fileName\": \"root@prod01.example.com.pub\"}
      ]
    }"
    mkdir -p "${VAULT_DIR}/attachments/${item_uuid}"
    printf 'DUMMY-PRIV\n' > "${VAULT_DIR}/attachments/${item_uuid}/${priv_uuid}"

    case "${mode}" in
      option_injection)
        printf 'command="/bin/evil" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKeyData root@host\n' \
          > "${VAULT_DIR}/attachments/${item_uuid}/${pub_uuid}"
        ;;
      embedded_newline)
        printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKeyData root@host\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvilSecondKey evil@host\n' \
          > "${VAULT_DIR}/attachments/${item_uuid}/${pub_uuid}"
        ;;
      bad_crypto)
        printf 'ssh-ed25519 AAAAnotavalided25519keypayload root@host\n' \
          > "${VAULT_DIR}/attachments/${item_uuid}/${pub_uuid}"
        ;;
    esac

    run_bw_keysetup root@prod01.example.com
    assert_ne "0" "${RUN_RC}" "${mode}: rejects malicious public key"
    assert_file_not_exists "${FAKE_ROOT}/root/.ssh/authorized_keys" "${mode}: authorized_keys never created"
  done
}

test_security_sshd_case_insensitive_and_equals() {
  # Lowercase directive and equals-sign directive before lowercase Match block.
  setup_case "security_sshd_case_direct" "direct"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Port 22
permitrootlogin yes
PermitRootLogin=yes
PasswordAuthentication yes

match user=admin
    PermitRootLogin yes
EOF

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "exit code"

  local cfg
  cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  assert_contains "${cfg}" "PermitRootLogin prohibit-password" "sets PermitRootLogin prohibit-password"
  assert_not_contains "${cfg}" "permitrootlogin yes" "replaces lowercase permitrootlogin"
  assert_not_contains "${cfg}" "PermitRootLogin=yes" "replaces equals-sign PermitRootLogin=yes"
  assert_contains "${cfg}" "match user=admin" "preserves lowercase match block"

  # Lowercase Include directive uses drop-in mode.
  setup_case "security_sshd_case_dropin" "dropin"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
include /etc/ssh/sshd_config.d/*.conf
Port 22
EOF

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "lowercase include exit code"
  assert_eq "PermitRootLogin prohibit-password" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf")" "wrote drop-in on lowercase include"
}

test_security_sshd_effective_config_rollback() {
  # Effective PermitRootLogin != prohibit-password triggers rollback.
  setup_case "security_sshd_eff_root" "dropin"
  MOCK_EFFECTIVE_ROOT_LOGIN="yes" run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "fails when effective PermitRootLogin is yes"
  assert_contains "${RUN_STDERR}" "Effective PermitRootLogin" "reports effective PermitRootLogin mismatch"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "drop-in removed on rollback"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on rollback"

  # Effective PubkeyAuthentication != yes triggers rollback.
  setup_case "security_sshd_eff_pubkey" "direct"
  local orig_cfg
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_EFFECTIVE_PUBKEY="no" run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "fails when effective PubkeyAuthentication is no"
  assert_contains "${RUN_STDERR}" "Effective PubkeyAuthentication" "reports effective PubkeyAuthentication mismatch"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted on rollback"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.bak" "sshd_config.bak removed on rollback"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on rollback"
}

test_security_sshd_tmp_cfg_cleaned_on_failure() {
  setup_case "security_sshd_tmp_cfg" "direct"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "exits non-zero on sshd -t failure"

  local leftover
  leftover="$(find "${FAKE_ROOT}/etc/ssh" -name 'sshd_config.bw_keysetup.*' 2>/dev/null || true)"
  assert_eq "" "${leftover}" "no sshd_config.bw_keysetup.* temp files left behind"
}

test_security_invalid_salt_chars_regenerated() {
  setup_case "security_invalid_salt" "dropin"
  local item_uuid="10000000-0000-4000-8000-000000000040"
  seed_vault_item "${item_uuid}" "{
    \"id\": \"${item_uuid}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt\$Bad!Chars@Here#123456789012\", \"type\": 0}],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds after regenerating invalid salt"

  local new_salt salt_re
  salt_re='^[./0-9A-Za-z]{32,}$'
  new_salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${VAULT_DIR}/items/${item_uuid}.json")"
  if [[ ! "${new_salt}" =~ ${salt_re} ]]; then
    fail_msg "regenerated salt '${new_salt}' does not match allowed charset."
    return 1
  fi
}

test_security_password_with_newline_regenerated() {
  setup_case "security_pw_newline" "dropin"
  local item_uuid="10000000-0000-4000-8000-000000000041"
  seed_vault_item "${item_uuid}" "{
    \"id\": \"${item_uuid}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"LineOne1234567890\\nLineTwo1234567890\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt1234567890123456789012345678\", \"type\": 0}],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds after regenerating password with newline"
  assert_ge "$(count_pattern "${STATE_DIR}/bw_ops.log" "^edit item ${item_uuid}$")" 1 "edited item to replace newline password"

  local updated_pw
  updated_pw="$(jq -r '.login.password' "${VAULT_DIR}/items/${item_uuid}.json")"
  assert_ge "${#updated_pw}" 32 "regenerated password length >= 32"
  if [[ "${updated_pw}" == *$'\n'* ]]; then
    fail_msg "regenerated password must not contain newline."
    return 1
  fi
}

test_security_private_key_uploaded_before_pub() {
  setup_case "security_upload_order" "dropin"
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "exit code"

  local priv_line pub_line
  priv_line="$(grep -n 'create attachment .* root@prod01\.example\.com$' "${STATE_DIR}/bw_ops.log" | head -n1 | cut -d: -f1)"
  pub_line="$(grep -n 'create attachment .* root@prod01\.example\.com\.pub$' "${STATE_DIR}/bw_ops.log" | head -n1 | cut -d: -f1)"
  if [[ -z "${priv_line}" || -z "${pub_line}" || "${priv_line}" -ge "${pub_line}" ]]; then
    fail_msg "private key must be uploaded before .pub (priv=${priv_line}, pub=${pub_line})."
    return 1
  fi

  # When private key upload fails, no .pub is uploaded.
  setup_case "security_upload_order_priv_fail" "dropin"
  MOCK_ATTACH_PRIV_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when private key upload fails"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '\.pub$')" "no orphan .pub uploaded"
}

test_security_invalid_uuid_rejected() {
  setup_case "security_invalid_uuid" "dropin"
  MOCK_SEARCH_RETURN_ID="item-not-a-uuid" run_bw_keysetup root@prod01.example.com

  assert_eq "1" "${RUN_RC}" "rejects non-UUID itemID"
  assert_contains "${RUN_STDERR}" "invalid UUID" "stderr reports invalid UUID"
  assert_file_not_exists "${STATE_DIR}/ssh_calls.log" "no SSH calls on invalid UUID"
}

test_security_runtime_dir_rejects_disk() {
  setup_case "security_rt_disk" "dropin"
  local disk_dir="${CASE_DIR}/disk_runtime"
  mkdir -p "${disk_dir}"
  chmod 700 "${disk_dir}"

  CUSTOM_RUNTIME_DIR="${disk_dir}" run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds using /dev/shm fallback"
  assert_dir_empty "${disk_dir}" "disk-backed XDG_RUNTIME_DIR never used"
}

# --- Boundary and error paths ---

test_boundary_short_password_regenerated() {
  setup_case "boundary_short_pw" "dropin"
  local item_uuid="10000000-0000-4000-8000-000000000010"
  seed_vault_item "${item_uuid}" "{
    \"id\": \"${item_uuid}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"shortpw\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt1234567890123456789012345678\", \"type\": 0}],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "exit code"
  assert_ge "$(count_pattern "${STATE_DIR}/bw_ops.log" "^edit item ${item_uuid}$")" 1 "edited item"

  local updated_pw
  updated_pw="$(jq -r '.login.password' "${VAULT_DIR}/items/${item_uuid}.json")"
  assert_ge "${#updated_pw}" 32 "regenerated password length >= 32"
}

test_boundary_salt_variants() {
  local variant json_payload
  local item_uuid="10000000-0000-4000-8000-000000000020"
  for variant in short_salt empty_fields null_fields; do
    setup_case "boundary_salt_${variant}" "dropin"
    case "${variant}" in
      short_salt)
        json_payload="{
          \"id\": \"${item_uuid}\",
          \"type\": 1,
          \"name\": \"root@prod01.example.com\",
          \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
          \"fields\": [{\"name\": \"password_salt\", \"value\": \"tiny\", \"type\": 0}],
          \"attachments\": []
        }"
        ;;
      empty_fields)
        json_payload="{
          \"id\": \"${item_uuid}\",
          \"type\": 1,
          \"name\": \"root@prod01.example.com\",
          \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
          \"fields\": [],
          \"attachments\": []
        }"
        ;;
      null_fields)
        json_payload="{
          \"id\": \"${item_uuid}\",
          \"type\": 1,
          \"name\": \"root@prod01.example.com\",
          \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
          \"fields\": null,
          \"attachments\": []
        }"
        ;;
    esac

    seed_vault_item "${item_uuid}" "${json_payload}"
    run_bw_keysetup root@prod01.example.com
    assert_eq "0" "${RUN_RC}" "${variant} succeeds"

    local new_salt salt_count
    new_salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${VAULT_DIR}/items/${item_uuid}.json")"
    salt_count="$(jq '[.fields[] | select(.name == "password_salt")] | length' "${VAULT_DIR}/items/${item_uuid}.json")"
    assert_eq "1" "${salt_count}" "${variant} has single password_salt field"
    assert_ge "${#new_salt}" 32 "${variant} salt length >= 32"
  done
}

test_error_non_root_user() {
  setup_case "error_non_root" "dropin"
  MOCK_SSH_G_OUT="$(printf 'user alice\nhost prod01.example.com\n')" \
    run_bw_keysetup alice@prod01.example.com

  assert_eq "1" "${RUN_RC}" "non-root user exits 1"
  assert_contains "${RUN_STDERR}" "Target user must be root" "stderr rejects non-root"
  assert_file_not_exists "${STATE_DIR}/bw_ops.log" "no Bitwarden mutations"
  assert_file_not_exists "${STATE_DIR}/ssh_calls.log" "no remote ssh calls"
}

test_error_input_and_prereq_failures() {
  setup_case "error_zero_args" "dropin"
  run_bw_keysetup
  assert_eq "1" "${RUN_RC}" "zero args exits 1"
  assert_contains "${RUN_STDERR}" "Usage:" "usage printed on stderr"

  setup_case "error_bw_sess" "dropin"
  MOCK_SESS_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "bw.sess failure exits non-zero"

  setup_case "error_ssh_g" "dropin"
  MOCK_SSH_G_RC=255 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "ssh -G failure exits non-zero"

  setup_case "error_empty_host" "dropin"
  MOCK_SSH_G_OUT="user root" run_bw_keysetup root@
  assert_ne "0" "${RUN_RC}" "empty host exits non-zero"

  setup_case "error_slash_host" "dropin"
  MOCK_SSH_G_OUT="$(printf 'user root\nhost bad/host\n')" run_bw_keysetup root@bad/host
  assert_ne "0" "${RUN_RC}" "host with slash exits non-zero"
  assert_contains "${RUN_STDERR}" "must not contain a slash" "stderr rejects slash in host"
}

test_error_item_search_fails_closed() {
  local rc
  for rc in 1 3; do
    setup_case "error_search_rc_${rc}" "dropin"
    MOCK_SEARCH_RC="${rc}" run_bw_keysetup root@prod01.example.com
    assert_eq "${rc}" "${RUN_RC}" "propagates search exit ${rc}"
    assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no duplicate item created on exit ${rc}"
  done
}

test_error_privkey_lookup_fails_closed() {
  local rc
  for rc in 1 3; do
    setup_case "error_privkey_rc_${rc}" "dropin"
    MOCK_PRIVKEY_RC="${rc}" run_bw_keysetup root@prod01.example.com
    assert_eq "${rc}" "${RUN_RC}" "propagates privKeyID exit ${rc}"
    assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create attachment')" "no key uploaded on privKeyID exit ${rc}"
  done
}

test_error_pass_or_field_lookup_fails_closed() {
  local item_uuid_30="10000000-0000-4000-8000-000000000030"
  local item_uuid_31="10000000-0000-4000-8000-000000000031"

  setup_case "error_pass_rc1" "dropin"
  seed_vault_item "${item_uuid_30}" "{
    \"id\": \"${item_uuid_30}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"ExistingPassword1234567890123456\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"ExistingSalt12345678901234567890\", \"type\": 0}],
    \"attachments\": []
  }"
  MOCK_PASS_RC=1 run_bw_keysetup root@prod01.example.com
  assert_eq "1" "${RUN_RC}" "exits 1 when bw.item.pass fails"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^edit item')" "does not overwrite existing password"

  setup_case "error_field_rc1" "dropin"
  seed_vault_item "${item_uuid_31}" "{
    \"id\": \"${item_uuid_31}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"ExistingPassword1234567890123456\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"ExistingSalt12345678901234567890\", \"type\": 0}],
    \"attachments\": []
  }"
  MOCK_FIELD_RC=1 run_bw_keysetup root@prod01.example.com
  assert_eq "1" "${RUN_RC}" "exits 1 when bw.item.field fails"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^edit item')" "does not overwrite existing salt"
}

test_error_bw_generate_fails_closed() {
  setup_case "error_generate_fails" "dropin"
  MOCK_GEN_RC=1 run_bw_keysetup root@prod01.example.com

  assert_eq "1" "${RUN_RC}" "exits 1 when bw generate fails"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "does not create item with empty secret"
}

test_error_remote_shadow_rollback() {
  local mode orig_shadow orig_mode leftover
  for mode in chpasswd_fail verify_fail; do
    setup_case "error_shadow_${mode}" "dropin"
    orig_shadow="$(cat "${FAKE_ROOT}/etc/shadow")"
    orig_mode="$(stat -c '%a' "${FAKE_ROOT}/etc/shadow")"

    if [[ "${mode}" == "chpasswd_fail" ]]; then
      MOCK_CHPASSWD_RC=1 run_bw_keysetup root@prod01.example.com
    else
      MOCK_CHPASSWD_CORRUPT=1 run_bw_keysetup root@prod01.example.com
    fi

    assert_ne "0" "${RUN_RC}" "${mode} exits non-zero"
    assert_eq "${orig_shadow}" "$(cat "${FAKE_ROOT}/etc/shadow")" "${mode} restores /etc/shadow content"
    assert_eq "${orig_mode}" "$(stat -c '%a' "${FAKE_ROOT}/etc/shadow")" "${mode} preserves /etc/shadow permissions"
    leftover="$(find "${FAKE_ROOT}/etc" -name 'shadow.bw_keysetup.*' 2>/dev/null || true)"
    assert_eq "" "${leftover}" "${mode} removes shadow backup temp file"
  done
}

test_error_remote_sshd_t_fails_reverts() {
  # Drop-in mode rollback.
  setup_case "error_sshd_t_dropin" "dropin"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "drop-in mode exits non-zero when sshd -t fails"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "drop-in file removed on sshd -t failure"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on sshd -t failure"

  # Direct edit mode rollback.
  setup_case "error_sshd_t_direct" "direct"
  local orig_cfg
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "direct mode exits non-zero when sshd -t fails"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted on sshd -t failure"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.bak" "sshd_config.bak removed on revert"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on sshd -t failure"
}

test_error_attachment_upload_fails_cleans_tmp_dir() {
  setup_case "error_attach_priv_fails" "dropin"
  MOCK_ATTACH_PRIV_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "exits non-zero when private key attachment fails"
  assert_dir_empty "${RUNTIME_DIR}" "temp dir removed so no private key leaks"
}

run_test test_happy_fresh_host_dropin_mode
run_test test_happy_direct_sshd_config_edit_mode
run_test test_happy_idempotent_rerun
run_test test_security_jumper_symlink_attack_rejected
run_test test_security_malicious_pubkey_rejected_before_ssh
run_test test_security_sshd_case_insensitive_and_equals
run_test test_security_sshd_effective_config_rollback
run_test test_security_sshd_tmp_cfg_cleaned_on_failure
run_test test_security_invalid_salt_chars_regenerated
run_test test_security_password_with_newline_regenerated
run_test test_security_private_key_uploaded_before_pub
run_test test_security_invalid_uuid_rejected
run_test test_security_runtime_dir_rejects_disk
run_test test_boundary_short_password_regenerated
run_test test_boundary_salt_variants
run_test test_error_non_root_user
run_test test_error_input_and_prereq_failures
run_test test_error_item_search_fails_closed
run_test test_error_privkey_lookup_fails_closed
run_test test_error_pass_or_field_lookup_fails_closed
run_test test_error_bw_generate_fails_closed
run_test test_error_remote_shadow_rollback
run_test test_error_remote_sshd_t_fails_reverts
run_test test_error_attachment_upload_fails_cleans_tmp_dir

printf '\ntest_bw_keysetup.sh summary: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  exit 1
fi
