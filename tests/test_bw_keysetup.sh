#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW_KEYSETUP="${REPO_DIR}/bw.keysetup"

PASS_COUNT=0
FAIL_COUNT=0

TEST_ROOT="$(mktemp -d)"
RUNTIME_ROOT="$(mktemp -d "/dev/shm/bw_keysetup_test_rt.XXXXXXXXXX")"
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
printf 'bw.sess\n' >> "${STATE_DIR}/bw_ops.log"
exit "${MOCK_SESS_RC:-0}"
EOF

  # Stateful mock bw CLI emitting valid UUIDs and supporting attachment delete.
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
        if [[ "${MOCK_ATTACH_SLEEP:-0}" -eq 1 ]]; then
          dirname "${file_path}" > "${STATE_DIR}/attach.tmp_dir"
          sleep 30
        fi
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
        if [[ "${MOCK_HEX_ATT_ID:-0}" -eq 1 ]]; then
          att_id="$(printf 'a1b2%04x' "${seq_num}")"
        else
          att_id="$(printf 'aaaaaaaa-aaaa-4aaa-8aaa-%012d' "${seq_num}")"
        fi
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
  delete)
    sub="${1:-}"
    shift || true
    if [[ "${sub}" != "attachment" ]]; then
      exit 1
    fi
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
    printf 'delete attachment %s %s\n' "${item_id}" "${att_id}" >> "${STATE_DIR}/bw_ops.log"
    rm -f -- "${VAULT_DIR}/attachments/${item_id}/${att_id}"
    tmp_item="${VAULT_DIR}/items/${item_id}.json.tmp"
    jq --arg aid "${att_id}" \
      '.attachments = ((.attachments // []) | map(select(.id != $aid)))' \
      "${VAULT_DIR}/items/${item_id}.json" > "${tmp_item}"
    mv "${tmp_item}" "${VAULT_DIR}/items/${item_id}.json"
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

  # Stateful mock bw.item.pass matching real contract (0=password, 2=missing/null/empty, 1=error).
  cat > "${MOCK_BIN}/bw.item.pass" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_PASS_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_PASS_RC}"
fi
item_id="${1:-}"
pw="$(jq -r 'if (.login | type) == "object" and (.login.password | type) == "string" then .login.password else "" end' "${VAULT_DIR}/items/${item_id}.json")"
if [[ -z "${pw}" ]]; then
  exit 2
fi
printf '%s\n' "${pw}"
EOF

  # Stateful mock bw.item.field matching real contract (exit 3 on duplicates).
  cat > "${MOCK_BIN}/bw.item.field" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_FIELD_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_FIELD_RC}"
fi
item_id="${1:-}"
field_name="${2:-}"
cnt="$(jq -r --arg n "${field_name}" '[(.fields // [])[] | select(.name == $n)] | length' "${VAULT_DIR}/items/${item_id}.json")"
if [[ "${cnt}" -eq 0 ]]; then
  exit 2
elif [[ "${cnt}" -gt 1 ]]; then
  exit 3
fi
jq -r --arg n "${field_name}" '[(.fields // [])[] | select(.name == $n)][0] | if .value == null then "" else (.value | tostring) end' "${VAULT_DIR}/items/${item_id}.json"
EOF

  # Stateful mock bw.item.privKeyID using prefix matching (--prefix query --exclude-suffix .pub).
  cat > "${MOCK_BIN}/bw.item.privKeyID" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_PRIVKEY_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_PRIVKEY_RC}"
fi
item_id="${1:-}"
query="${2:-}"
mapfile -t ids < <(jq -r --arg p "${query}" '(.attachments // []) | map(select((.fileName | startswith($p)) and (.fileName | endswith(".pub") | not))) | .[].id' "${VAULT_DIR}/items/${item_id}.json")
if [[ "${#ids[@]}" -eq 0 ]]; then
  exit 2
elif [[ "${#ids[@]}" -gt 1 ]]; then
  exit 3
fi
printf '%s\n' "${ids[0]}"
EOF

  # Stateful mock bw.item.pubKeyID using prefix matching (--prefix query --suffix .pub).
  cat > "${MOCK_BIN}/bw.item.pubKeyID" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
item_id="${1:-}"
query="${2:-}"
mapfile -t ids < <(jq -r --arg p "${query}" '(.attachments // []) | map(select((.fileName | startswith($p)) and (.fileName | endswith(".pub")))) | .[].id' "${VAULT_DIR}/items/${item_id}.json")
if [[ "${#ids[@]}" -eq 0 ]]; then
  exit 2
elif [[ "${#ids[@]}" -gt 1 ]]; then
  exit 3
fi
printf '%s\n' "${ids[0]}"
EOF

  # Stateful mock ssh emitting real ssh -G keys (user, hostname) and executing against FAKE_ROOT.
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
    printf 'user root\nhostname prod01.example.com\n'
  fi
  exit 0
fi

if [[ "${MOCK_SSH_UNREACHABLE:-0}" -eq 1 ]]; then
  exit 255
fi

opts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-P|-p|-Q|-R|-S|-W|-w)
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
  script="${script//SSH_DIR=\"\/etc\/ssh\"/SSH_DIR=\"${FAKE_ROOT}\/etc\/ssh\"}"
  PATH="${FAKE_REMOTE_BIN}:/usr/bin:/bin" \
    FAKE_ROOT="${FAKE_ROOT}" \
    STATE_DIR="${STATE_DIR}" \
    /usr/bin/env bash <<< "${script}"
else
  remote_cmd="$*"
  remote_cmd="${remote_cmd//\/etc\/shadow/${FAKE_ROOT}\/etc\/shadow}"
  remote_cmd="${remote_cmd//\/etc\/login.defs/${FAKE_ROOT}\/etc\/login.defs}"
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
    if [[ -z "${target}" ]]; then
      printf '%s\n' "${MOCK_REMOTE_UID:-0}"
      exit 0
    fi
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

  cat > "${FAKE_REMOTE_BIN}/su" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'su %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
# Enforce expected argument order: su -s /bin/sh -c <script> -- <target_user>
if [[ "${1:-}" != "-s" || "${2:-}" != "/bin/sh" || "${3:-}" != "-c" || "${5:-}" != "--" || -z "${6:-}" ]]; then
  echo "Error: Invalid su argument order: $*" >&2
  exit 2
fi
exec /bin/sh -c "${4}"
EOF

  cat > "${FAKE_REMOTE_BIN}/restorecon" <<'EOF'
#!/usr/bin/env bash
printf 'restorecon %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
exit 0
EOF

  cat > "${FAKE_REMOTE_BIN}/useradd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "${STATE_DIR}/useradd.argv0"
printf 'useradd %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"

create_home=0
comment=""
shell="/bin/sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      create_home=1
      shift
      ;;
    -s)
      shell="${2:-/bin/sh}"
      shift 2
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
printf '%s:x:%s:%s:%s:%s:%s\n' "${username}" "${cur_uid}" "${cur_gid}" "${comment}" "${home_dir}" "${shell}" >> "${FAKE_ROOT}/etc/passwd"
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

  cat > "${FAKE_REMOTE_BIN}/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >> "${STATE_DIR}/remote_ops.log"
if [[ "${1:-}" == "-t" ]]; then
  exit "${MOCK_SSHD_T_RC:-0}"
elif [[ "${1:-}" == "-T" ]]; then
  if [[ "${MOCK_SSHD_CAP_T_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_SSHD_CAP_T_RC}"
  fi
  if [[ "$*" == *"example.invalid"* && -n "${MOCK_EFFECTIVE_ROOT_LOGIN_EXT:-}" ]]; then
    printf 'permitrootlogin %s\n' "${MOCK_EFFECTIVE_ROOT_LOGIN_EXT}"
  else
    printf 'permitrootlogin %s\n' "${MOCK_EFFECTIVE_ROOT_LOGIN:-prohibit-password}"
  fi
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
  if [[ "${MOCK_SSH_UNIT:-ssh.service}" != "none" && "${unit}" == "${MOCK_SSH_UNIT:-ssh.service}" ]]; then
    printf '%s enabled\n' "${unit}"
  fi
  exit 0
elif [[ "${1:-}" == "reload-or-restart" ]]; then
  if [[ "${MOCK_SYSTEMCTL_RELOAD_FAIL_ONCE:-0}" -eq 1 && ! -f "${STATE_DIR}/reload.failed_once" ]]; then
    touch "${STATE_DIR}/reload.failed_once"
    exit 1
  fi
  exit "${MOCK_SYSTEMCTL_RELOAD_RC:-0}"
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
    "${FAKE_REMOTE_BIN}/su" \
    "${FAKE_REMOTE_BIN}/restorecon" \
    "${FAKE_REMOTE_BIN}/useradd" \
    "${FAKE_REMOTE_BIN}/chpasswd" \
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

  local item_file pw salt expected_hash actual_hash user_name
  for item_file in "${root_item}" "${jumper_item}"; do
    user_name="$(jq -r '.login.username' "${item_file}")"
    assert_eq "object" "$(jq -r '.login | type' "${item_file}")" "${user_name} .login is object"
    pw="$(jq -r '.login.password' "${item_file}")"
    salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${item_file}")"
    assert_ge "${#pw}" 32 "${user_name} password length >= 32"
    assert_eq "32" "${#salt}" "${user_name} salt length is 32"

    assert_not_contains "${RUN_STDOUT}" "${pw}" "stdout omits ${user_name} password"
    assert_not_contains "${RUN_STDOUT}" "${salt}" "stdout omits ${user_name} salt"
    assert_not_contains "${RUN_STDOUT}" '"password_salt"' "stdout omits raw item JSON"

    expected_hash="$(compute_yescrypt "${pw}" "${salt}")"
    actual_hash="$(awk -F: -v u="${user_name}" '$1 == u { print $2 }' "${FAKE_ROOT}/etc/shadow")"
    assert_contains "${actual_hash}" "\$y\$j9T\$" "${user_name} shadow has Yescrypt prefix"
    assert_eq "${expected_hash}" "${actual_hash}" "${user_name} shadow hash matches perl crypt"
  done

  # Verify useradd received explicit login shell and quoted comment.
  local -a useradd_args=()
  mapfile -d '' -t useradd_args < "${STATE_DIR}/useradd.argv0"
  assert_eq "6" "${#useradd_args[@]}" "useradd arg count"
  assert_eq "-m" "${useradd_args[0]}" "useradd -m"
  assert_eq "-s" "${useradd_args[1]}" "useradd -s"
  assert_eq "/bin/bash" "${useradd_args[2]}" "useradd login shell"
  assert_eq "-c" "${useradd_args[3]}" "useradd -c"
  assert_eq "jumper user" "${useradd_args[4]}" "useradd comment"
  assert_eq "jumper" "${useradd_args[5]}" "useradd username"

  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "runuser -u jumper" "dropped privileges via runuser"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "restorecon -R -- ${FAKE_ROOT}/root/.ssh" "ran restorecon on root .ssh"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "restorecon -R -- ${FAKE_ROOT}/home/jumper/.ssh" "ran restorecon on jumper .ssh"

  local root_id jumper_id root_pub_id jumper_pub_id root_pub jumper_pub
  root_id="$(jq -r '.id' "${root_item}")"
  jumper_id="$(jq -r '.id' "${jumper_item}")"
  root_pub_id="$(jq -r '.attachments[] | select(.fileName == "root@prod01.example.com.pub") | .id' "${root_item}")"
  jumper_pub_id="$(jq -r '.attachments[] | select(.fileName == "jumper@prod01.example.com.pub") | .id' "${jumper_item}")"
  assert_ne "" "${root_pub_id}" "root .pub uploaded"
  assert_ne "" "${jumper_pub_id}" "jumper .pub uploaded"

  root_pub="$(cat "${VAULT_DIR}/attachments/${root_id}/${root_pub_id}")"
  jumper_pub="$(cat "${VAULT_DIR}/attachments/${jumper_id}/${jumper_pub_id}")"
  assert_contains "${root_pub}" "ssh-ed25519 " "root key is ed25519"
  assert_contains "${jumper_pub}" "ssh-ed25519 " "jumper key is ed25519"

  local root_ak jumper_ak
  root_ak="$(cat "${FAKE_ROOT}/root/.ssh/authorized_keys")"
  jumper_ak="$(cat "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys")"
  assert_contains "${root_ak}" "${root_pub}" "root authorized_keys contains root key"
  assert_not_contains "${root_ak}" "${jumper_pub}" "root authorized_keys omits jumper key"
  assert_contains "${jumper_ak}" "${jumper_pub}" "jumper authorized_keys contains jumper key"
  assert_not_contains "${jumper_ak}" "${root_pub}" "jumper authorized_keys omits root key"

  assert_dir_empty "${RUNTIME_DIR}" "XDG_RUNTIME_DIR has no remaining temp dirs"

  # Verify -o RequestTTY=no and custom SSH options on every remote ssh call.
  local total_ssh_calls matching_ssh_calls
  total_ssh_calls="$(wc -l < "${STATE_DIR}/ssh_calls.log")"
  matching_ssh_calls="$(count_pattern "${STATE_DIR}/ssh_calls.log" 'OPTS=\[(-n )?-o RequestTTY=no -p 2222 -o StrictHostKeyChecking=no\]')"
  assert_ge "${total_ssh_calls}" 7 "at least 7 remote ssh calls including preflight"
  assert_eq "${total_ssh_calls}" "${matching_ssh_calls}" "every ssh call sets RequestTTY=no and forwards options"

  # Verify sshd drop-in mode 0600, both sshd -T contexts, and reload.
  assert_eq "PermitRootLogin prohibit-password" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf")" "sshd drop-in written"
  assert_eq "600" "$(stat -c '%a' "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf")" "sshd drop-in mode 0600"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "sshd -T -C user=root,host=localhost,addr=127.0.0.1" "verified localhost sshd context"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "sshd -T -C user=root,host=example.invalid,addr=192.0.2.1" "verified remote sshd context"
  assert_contains "$(cat "${STATE_DIR}/systemctl.log")" "systemctl reload-or-restart ssh.service" "reloaded ssh.service"
}

test_happy_hex_attachment_ids_supported() {
  setup_case "happy_hex_att_ids" "dropin"
  MOCK_HEX_ATT_ID=1 run_bw_keysetup root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "succeeds with 8-char hex attachment IDs"
  assert_file_exists "${FAKE_ROOT}/root/.ssh/authorized_keys" "root key installed with hex attachment ID"
}

test_happy_direct_sshd_config_edit_and_prose_preservation() {
  setup_case "happy_direct_sshd" "direct"
  # Seed a pre-existing sshd_config.bak that must never be clobbered.
  printf 'PREEXISTING-BACKUP\n' > "${FAKE_ROOT}/etc/ssh/sshd_config.bak"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Port 22
# PermitRootLogin is managed by ops
# PermitRootLogin yes
PasswordAuthentication yes

Match User admin
    PermitRootLogin yes
EOF

  run_bw_keysetup root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "PREEXISTING-BACKUP" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.bak")" "pre-existing .bak preserved untouched"

  local cfg match_line global_line
  cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  assert_contains "${cfg}" "# PermitRootLogin is managed by ops" "prose comment preserved"
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

test_happy_authorized_keys_no_trailing_newline_and_dedup() {
  setup_case "happy_ak_no_newline" "dropin"
  mkdir -p "${FAKE_ROOT}/root/.ssh"
  chmod 700 "${FAKE_ROOT}/root/.ssh"
  # Write an existing key with NO trailing newline.
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyOnlyForTest existing@admin' \
    > "${FAKE_ROOT}/root/.ssh/authorized_keys"
  chmod 600 "${FAKE_ROOT}/root/.ssh/authorized_keys"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "first run succeeds"

  local line_count
  line_count="$(wc -l < "${FAKE_ROOT}/root/.ssh/authorized_keys")"
  assert_eq "2" "${line_count}" "existing key and new key occupy separate lines"
  assert_eq "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExistingKeyOnlyForTest existing@admin" \
    "$(sed -n '1p' "${FAKE_ROOT}/root/.ssh/authorized_keys")" "line 1 preserves existing key"
  assert_contains "$(sed -n '2p' "${FAKE_ROOT}/root/.ssh/authorized_keys")" "root@prod01.example.com" "line 2 holds new key"

  # Re-run must deduplicate without duplicating either key.
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "second run succeeds"
  line_count="$(wc -l < "${FAKE_ROOT}/root/.ssh/authorized_keys")"
  assert_eq "2" "${line_count}" "rerun preserves exact 2 lines without duplication"
}

test_happy_su_fallback_when_runuser_absent() {
  setup_case "happy_su_fallback" "dropin"
  rm -f "${FAKE_REMOTE_BIN}/runuser"
  run_bw_keysetup root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "succeeds using su fallback"
  assert_contains "$(cat "${STATE_DIR}/remote_ops.log")" "su -s /bin/sh -c " "invoked su with correct argument order"
  assert_file_exists "${FAKE_ROOT}/home/jumper/.ssh/authorized_keys" "jumper authorized_keys installed via su"
}

test_happy_sshd_service_selection_and_include_variants() {
  # Verify sshd.service selection when ssh.service is absent.
  setup_case "happy_sshd_unit" "dropin"
  MOCK_SSH_UNIT="sshd.service" run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds with sshd.service"
  assert_contains "$(cat "${STATE_DIR}/systemctl.log")" "systemctl reload-or-restart sshd.service" "reloaded sshd.service"

  # Verify relative Include sshd_config.d/*.conf activates drop-in mode.
  setup_case "happy_relative_include" "dropin"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Include sshd_config.d/*.conf
Port 22
EOF
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds with relative Include"
  assert_file_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "wrote drop-in for relative Include"

  # Verify quoted Include "/etc/ssh/sshd_config.d/*.conf" activates drop-in mode.
  setup_case "happy_quoted_include" "dropin"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Include "/etc/ssh/sshd_config.d/*.conf"
Port 22
EOF
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds with quoted Include"
  assert_file_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "wrote drop-in for quoted Include"
}

test_happy_idempotent_rerun() {
  setup_case "happy_idempotent" "dropin"
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "first run succeeds"

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

test_security_preflight_blocks_vault_mutation() {
  # Unreachable SSH fails before creating any Bitwarden items.
  setup_case "security_preflight_unreachable" "dropin"
  MOCK_SSH_UNREACHABLE=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when SSH is unreachable"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no Bitwarden item created when unreachable"

  # Non-root remote UID fails before creating any Bitwarden items.
  setup_case "security_preflight_nonroot_uid" "dropin"
  MOCK_REMOTE_UID=1000 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when remote UID is 1000"
  assert_contains "${RUN_STDERR}" "Remote shell UID must be 0" "reports non-root remote UID"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no Bitwarden item created on non-root UID"

  # Unsupported Yescrypt fails before creating any Bitwarden items.
  setup_case "security_preflight_no_yescrypt" "dropin"
  cat > "${FAKE_REMOTE_BIN}/perl" <<'EOF'
#!/usr/bin/env bash
printf 'ab12345678901\n'
EOF
  chmod +x "${FAKE_REMOTE_BIN}/perl"
  run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when remote host lacks Yescrypt support"
  assert_contains "${RUN_STDERR}" "does not support Yescrypt" "reports missing Yescrypt support"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no Bitwarden item created without Yescrypt"
}

test_security_include_after_permitrootlogin_uses_direct_edit() {
  setup_case "security_include_after_prl" "dropin"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
Port 22
PermitRootLogin yes
Include /etc/ssh/sshd_config.d/*.conf
EOF

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds by editing sshd_config directly"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "does not write ineffective drop-in"
  assert_contains "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "PermitRootLogin prohibit-password" "replaces active PermitRootLogin in sshd_config"
  assert_not_contains "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "PermitRootLogin yes" "removes PermitRootLogin yes"
}

test_security_cp_failure_does_not_destroy_shadow_or_sshd_config() {
  # cp -a failure during /etc/shadow backup must keep /etc/shadow intact.
  setup_case "security_cp_fail_shadow" "dropin"
  local orig_shadow
  orig_shadow="$(cat "${FAKE_ROOT}/etc/shadow")"
  cat > "${FAKE_REMOTE_BIN}/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"shadow"* ]]; then
  exit 1
fi
exec /usr/bin/cp "$@"
EOF
  chmod +x "${FAKE_REMOTE_BIN}/cp"

  run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when cp -a fails on /etc/shadow"
  assert_eq "${orig_shadow}" "$(cat "${FAKE_ROOT}/etc/shadow")" "/etc/shadow stays intact after cp failure"
  assert_eq "" "$(find "${FAKE_ROOT}/etc" -name 'shadow.bw_keysetup.*' 2>/dev/null || true)" "empty backup deleted"

  # cp -a failure during sshd_config backup must keep sshd_config intact.
  setup_case "security_cp_fail_sshd" "direct"
  local orig_cfg
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  cat > "${FAKE_REMOTE_BIN}/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"sshd_config"* ]]; then
  exit 1
fi
exec /usr/bin/cp "$@"
EOF
  chmod +x "${FAKE_REMOTE_BIN}/cp"

  run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when cp -a fails on sshd_config"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config stays intact after cp failure"
  assert_eq "" "$(find "${FAKE_ROOT}/etc/ssh" -name 'sshd_config.bw_keysetup.*' 2>/dev/null || true)" "empty backup deleted"
}

test_security_pub_upload_failure_reverts_priv_and_orphan_pub_rejected() {
  # When .pub upload fails, delete the just-uploaded private key so a retry succeeds.
  setup_case "security_pub_fail_rollback" "dropin"
  MOCK_ATTACH_PUB_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when .pub upload fails"
  assert_eq "1" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^delete attachment ')" "deleted partial private key attachment"

  local root_item att_count
  root_item="$(find_vault_item_file "root@prod01.example.com")"
  att_count="$(jq '.attachments | length' "${root_item}")"
  assert_eq "0" "${att_count}" "zero leftover attachments after partial failure"

  # Retry without failure succeeds cleanly without wedging.
  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "retry succeeds after partial upload rollback"
  att_count="$(jq '.attachments | length' "${root_item}")"
  assert_eq "2" "${att_count}" "both private and public attachments exist after retry"

  # Existing orphan .pub attachment must fail closed before generating a new keypair.
  setup_case "security_orphan_pub_rejected" "dropin"
  local item_uuid="10000000-0000-4000-8000-000000000077"
  local orphan_pub_id="aaaaaaaa-aaaa-4aaa-8aaa-000000000078"
  seed_vault_item "${item_uuid}" "{
    \"id\": \"${item_uuid}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt1234567890123456789012345678\", \"type\": 0}],
    \"attachments\": [{\"id\": \"${orphan_pub_id}\", \"fileName\": \"root@prod01.example.com.pub\"}]
  }"
  run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "rejects orphan .pub attachment"
  assert_contains "${RUN_STDERR}" "Orphan public key attachment" "stderr reports orphan .pub"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create attachment')" "no new keypair uploaded over orphan .pub"
}

test_security_non_login_item_rejected_in_checkPassLen() {
  setup_case "security_non_login_item" "dropin"
  local item_uuid="10000000-0000-4000-8000-000000000088"
  seed_vault_item "${item_uuid}" "{
    \"id\": \"${item_uuid}\",
    \"type\": 2,
    \"name\": \"root@prod01.example.com\",
    \"login\": null,
    \"fields\": [],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "rejects non-login vault item"
  assert_contains "${RUN_STDERR}" "not a login item" "stderr reports non-login item"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^edit item')" "does not edit non-login item"
}

test_security_jumper_nologin_shell_rejected() {
  local cur_uid cur_gid bad_shell shell_tag
  cur_uid="$(/usr/bin/id -u)"
  cur_gid="$(/usr/bin/id -g)"

  for bad_shell in /sbin/nologin /usr/sbin/nologin /usr/bin/nologin /bin/false /usr/bin/false; do
    shell_tag="${bad_shell//\//_}"
    setup_case "security_jumper${shell_tag}" "dropin"
    printf 'jumper:x:%s:%s:jumper user:%s/home/jumper:%s\n' "${cur_uid}" "${cur_gid}" "${FAKE_ROOT}" "${bad_shell}" >> "${FAKE_ROOT}/etc/passwd"
    printf 'jumper:!:19000:0:99999:7:::\n' >> "${FAKE_ROOT}/etc/shadow"

    run_bw_keysetup root@prod01.example.com
    assert_ne "0" "${RUN_RC}" "rejects jumper with ${bad_shell}"
    assert_contains "${RUN_STDERR}" "non-interactive shell" "stderr reports non-interactive shell for ${bad_shell}"
  done
}

test_security_jumper_symlink_attack_rejected() {
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
  assert_not_contains "$(cat "${FAKE_ROOT}/root/.ssh/authorized_keys")" "jumper@prod01.example.com" "root authorized_keys untouched"

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

  setup_case "security_sshd_case_dropin" "dropin"
  cat > "${FAKE_ROOT}/etc/ssh/sshd_config" <<'EOF'
include /etc/ssh/sshd_config.d/*.conf
Port 22
EOF

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "lowercase include exit code"
  assert_eq "PermitRootLogin prohibit-password" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf")" "wrote drop-in on lowercase include"
}

test_security_sshd_effective_config_and_systemd_rollback() {
  # Effective PermitRootLogin != prohibit-password on remote context triggers rollback.
  setup_case "security_sshd_eff_ext" "dropin"
  MOCK_EFFECTIVE_ROOT_LOGIN_EXT="yes" run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when non-localhost PermitRootLogin is yes"
  assert_contains "${RUN_STDERR}" "example.invalid" "reports failed remote context"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "drop-in deleted on rollback"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on rollback"

  # Effective PubkeyAuthentication != yes triggers rollback.
  setup_case "security_sshd_eff_pubkey" "direct"
  local orig_cfg
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_EFFECTIVE_PUBKEY="no" run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when effective PubkeyAuthentication is no"
  assert_contains "${RUN_STDERR}" "Effective PubkeyAuthentication" "reports effective PubkeyAuthentication mismatch"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted on rollback"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on rollback"

  # Missing systemd unit triggers rollback.
  setup_case "security_sshd_missing_unit" "direct"
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_SSH_UNIT="none" run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when neither ssh.service nor sshd.service exists"
  assert_contains "${RUN_STDERR}" "Cannot find ssh or sshd systemd unit" "reports missing systemd unit"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted on missing unit"

  # Failed systemctl reload-or-restart reverts config and reloads again.
  setup_case "security_sshd_reload_fail_reverts" "direct"
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_SYSTEMCTL_RELOAD_FAIL_ONCE=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "fails when systemctl reload fails"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted after reload failure"
  assert_eq "2" "$(count_pattern "${STATE_DIR}/systemctl.log" '^systemctl reload-or-restart ssh\.service$')" "attempts reload again after revert"
}

test_security_sshd_tmp_cfg_cleaned_on_failure() {
  setup_case "security_sshd_tmp_cfg" "direct"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "exits non-zero on sshd -t failure"

  local leftover
  leftover="$(find "${FAKE_ROOT}/etc/ssh" -name 'sshd_config.bw_keysetup.*' 2>/dev/null || true)"
  assert_eq "" "${leftover}" "no sshd_config.bw_keysetup.* temp files remain"
}

test_security_salt_validation_and_duplicate_rejection() {
  # Invalid salt characters regenerated.
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
  salt_re='^([./0-9A-Za-z]{4}){8,16}$'
  new_salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${VAULT_DIR}/items/${item_uuid}.json")"
  if [[ ! "${new_salt}" =~ ${salt_re} ]]; then
    fail_msg "regenerated salt '${new_salt}' fails canonical SALT_RE."
    return 1
  fi

  # Non-canonical 33-char salt (not a multiple of 4) must be regenerated.
  setup_case "security_salt_33_chars" "dropin"
  local item_uuid_33="10000000-0000-4000-8000-000000000043"
  seed_vault_item "${item_uuid_33}" "{
    \"id\": \"${item_uuid_33}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
    \"fields\": [{\"name\": \"password_salt\", \"value\": \"Salt12345678901234567890123456789\", \"type\": 0}],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds after regenerating 33-char salt"
  assert_ge "$(count_pattern "${STATE_DIR}/bw_ops.log" "^edit item ${item_uuid_33}$")" 1 "edited item for 33-char salt"
  new_salt="$(jq -r '.fields[] | select(.name == "password_salt") | .value' "${VAULT_DIR}/items/${item_uuid_33}.json")"
  assert_eq "32" "${#new_salt}" "regenerated salt length is 32"

  # Duplicate password_salt fields must fail closed (exit 3).
  setup_case "security_duplicate_salt" "dropin"
  local item_uuid_dup="10000000-0000-4000-8000-000000000044"
  seed_vault_item "${item_uuid_dup}" "{
    \"id\": \"${item_uuid_dup}\",
    \"type\": 1,
    \"name\": \"root@prod01.example.com\",
    \"login\": {\"username\": \"root\", \"password\": \"Pass1234567890123456789012345678\", \"totp\": \"\"},
    \"fields\": [
      {\"name\": \"password_salt\", \"value\": \"Salt1234567890123456789012345678\", \"type\": 0},
      {\"name\": \"password_salt\", \"value\": \"Salt9999999999999999999999999999\", \"type\": 0}
    ],
    \"attachments\": []
  }"

  run_bw_keysetup root@prod01.example.com
  assert_eq "3" "${RUN_RC}" "exits 3 on duplicate password_salt"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^edit item')" "does not overwrite duplicate salt fields"
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
  assert_eq "1" "$(wc -l < "${STATE_DIR}/ssh_calls.log")" "only read-only preflight ran before invalid UUID"
}

test_security_runtime_dir_rejects_disk_and_symlink_ancestor() {
  setup_case "security_rt_disk" "dropin"
  local disk_dir="${CASE_DIR}/disk_runtime"
  mkdir -p "${disk_dir}"
  chmod 700 "${disk_dir}"

  CUSTOM_RUNTIME_DIR="${disk_dir}" run_bw_keysetup root@prod01.example.com
  assert_eq "0" "${RUN_RC}" "succeeds using /dev/shm"
  assert_dir_empty "${disk_dir}" "disk-backed XDG_RUNTIME_DIR never used"

  setup_case "security_rt_symlink_ancestor" "dropin"
  local link_anc="${RUNTIME_ROOT}/ks_anc_link"
  ln -s "${RUNTIME_DIR}" "${link_anc}"
  mkdir -p "${RUNTIME_DIR}/nested"
  chmod 700 "${RUNTIME_DIR}/nested"

  CUSTOM_RUNTIME_DIR="${link_anc}/nested" run_bw_keysetup root@prod01.example.com
  rm -f "${link_anc}"
  assert_eq "0" "${RUN_RC}" "succeeds using /dev/shm on symlinked ancestor"
  assert_dir_empty "${RUNTIME_DIR}/nested" "symlinked ancestor dir never used"
}

test_signal_sigterm_cleans_up_tmp_dir() {
  setup_case "signal_sigterm" "dropin"
  local bg_pid=0
  local wait_i=0
  local tmp_dir=""
  local sig_rc=0

  PATH="${MOCK_BIN}:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
    VAULT_DIR="${VAULT_DIR}" \
    FAKE_ROOT="${FAKE_ROOT}" \
    FAKE_REMOTE_BIN="${FAKE_REMOTE_BIN}" \
    STATE_DIR="${STATE_DIR}" \
    MOCK_ATTACH_SLEEP=1 \
    setsid "${BW_KEYSETUP}" root@prod01.example.com >"${STATE_DIR}/stdout" 2>"${STATE_DIR}/stderr" &
  bg_pid=$!

  while [[ ! -s "${STATE_DIR}/attach.tmp_dir" && "${wait_i}" -lt 80 ]]; do
    sleep 0.1
    wait_i=$((wait_i + 1))
  done

  if [[ ! -s "${STATE_DIR}/attach.tmp_dir" ]]; then
    kill -KILL -- -"${bg_pid}" 2>/dev/null || true
    fail_msg "bw create attachment did not start in time."
    return 1
  fi

  tmp_dir="$(cat "${STATE_DIR}/attach.tmp_dir")"
  kill -TERM -- -"${bg_pid}" 2>/dev/null || true
  wait "${bg_pid}" || sig_rc=$?

  assert_ne "0" "${sig_rc}" "non-zero exit after SIGTERM"
  assert_file_not_exists "${tmp_dir}" "temp key dir deleted on SIGTERM"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean after SIGTERM"
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
    assert_eq "32" "${#new_salt}" "${variant} salt length is 32"
  done
}

test_error_non_root_user() {
  setup_case "error_non_root" "dropin"
  MOCK_SSH_G_OUT="$(printf 'user alice\nhostname prod01.example.com\n')" \
    run_bw_keysetup alice@prod01.example.com

  assert_eq "1" "${RUN_RC}" "non-root user exits 1"
  assert_contains "${RUN_STDERR}" "Target user must be root" "stderr rejects non-root"
  assert_eq "0" "$(count_pattern "${STATE_DIR}/bw_ops.log" '^create item')" "no Bitwarden mutations"
  assert_file_not_exists "${STATE_DIR}/ssh_calls.log" "no remote ssh calls"
}

test_error_cli_args_and_incompatible_flags() {
  setup_case "error_zero_args" "dropin"
  run_bw_keysetup
  assert_eq "1" "${RUN_RC}" "zero args exits 1"
  assert_contains "${RUN_STDERR}" "Usage: bw.keysetup [ssh-options] root@<host>" "usage printed on stderr"

  # Reject trailing positional args after destination.
  setup_case "error_trailing_flag" "dropin"
  run_bw_keysetup root@prod01.example.com -p 2222
  assert_eq "1" "${RUN_RC}" "rejects trailing -p after destination"
  assert_contains "${RUN_STDERR}" "Unexpected argument after destination" "reports trailing arg"
  assert_file_not_exists "${STATE_DIR}/bw_ops.log" "does not call bw.sess on bad args"

  setup_case "error_trailing_cmd" "dropin"
  run_bw_keysetup root@prod01.example.com id
  assert_eq "1" "${RUN_RC}" "rejects trailing command after destination"
  assert_contains "${RUN_STDERR}" "Unexpected argument after destination" "reports trailing command"

  # Reject incompatible SSH flags.
  local flag
  for flag in -N -f -t -W -G -V; do
    setup_case "error_flag_${flag#-}" "dropin"
    if [[ "${flag}" == "-W" ]]; then
      run_bw_keysetup -W host:22 root@prod01.example.com
    elif [[ "${flag}" == "-V" ]]; then
      run_bw_keysetup -V
    else
      run_bw_keysetup "${flag}" root@prod01.example.com
    fi
    assert_eq "1" "${RUN_RC}" "rejects incompatible option ${flag}"
    assert_contains "${RUN_STDERR}" "does not support option ${flag}" "reports unsupported option ${flag}"
    assert_file_not_exists "${STATE_DIR}/bw_ops.log" "does not call bw.sess for ${flag}"
  done

  setup_case "error_bw_sess" "dropin"
  MOCK_SESS_RC=1 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "bw.sess failure exits non-zero"

  setup_case "error_ssh_g" "dropin"
  MOCK_SSH_G_RC=255 run_bw_keysetup root@prod01.example.com
  assert_ne "0" "${RUN_RC}" "ssh -G failure exits non-zero"

  setup_case "error_empty_host" "dropin"
  MOCK_SSH_G_OUT="user root" run_bw_keysetup root@
  assert_ne "0" "${RUN_RC}" "empty hostname exits non-zero"

  setup_case "error_slash_host" "dropin"
  MOCK_SSH_G_OUT="$(printf 'user root\nhostname bad/host\n')" run_bw_keysetup root@bad/host
  assert_ne "0" "${RUN_RC}" "hostname with slash exits non-zero"
  assert_contains "${RUN_STDERR}" "invalid characters" "stderr rejects invalid hostname"

  setup_case "error_dash_host" "dropin"
  MOCK_SSH_G_OUT="$(printf 'user root\nhostname -badhost\n')" run_bw_keysetup root@-badhost
  assert_ne "0" "${RUN_RC}" "hostname starting with dash exits non-zero"
  assert_contains "${RUN_STDERR}" "invalid characters" "stderr rejects leading dash hostname"
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
    assert_eq "" "${leftover}" "${mode} deletes shadow backup temp file"
  done
}

test_error_remote_sshd_t_fails_reverts() {
  setup_case "error_sshd_t_dropin" "dropin"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "drop-in mode exits non-zero when sshd -t fails"
  assert_file_not_exists "${FAKE_ROOT}/etc/ssh/sshd_config.d/00-bw-keysetup.conf" "drop-in file deleted on sshd -t failure"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on sshd -t failure"

  setup_case "error_sshd_t_direct" "direct"
  printf 'KEEP-ME\n' > "${FAKE_ROOT}/etc/ssh/sshd_config.bak"
  local orig_cfg
  orig_cfg="$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")"
  MOCK_SSHD_T_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "direct mode exits non-zero when sshd -t fails"
  assert_eq "${orig_cfg}" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config")" "sshd_config reverted on sshd -t failure"
  assert_eq "KEEP-ME" "$(cat "${FAKE_ROOT}/etc/ssh/sshd_config.bak")" "pre-existing .bak preserved on rollback"
  assert_file_not_exists "${STATE_DIR}/systemctl.log" "systemctl not called on sshd -t failure"
}

test_error_attachment_upload_fails_cleans_tmp_dir() {
  setup_case "error_attach_priv_fails" "dropin"
  MOCK_ATTACH_PRIV_RC=1 run_bw_keysetup root@prod01.example.com

  assert_ne "0" "${RUN_RC}" "exits non-zero when private key attachment fails"
  assert_dir_empty "${RUNTIME_DIR}" "temp dir deleted so no private key leaks"
}

test_regression_ssh_tag_option_p_accepted() {
  setup_case "regression_tag_p_opt" "dropin"
  run_bw_keysetup -P mytag root@prod01.example.com

  assert_eq "0" "${RUN_RC}" "-P mytag root@prod01.example.com exits 0"
  local total_ssh_calls matching_ssh_calls
  total_ssh_calls="$(wc -l < "${STATE_DIR}/ssh_calls.log")"
  matching_ssh_calls="$(count_pattern "${STATE_DIR}/ssh_calls.log" 'OPTS=\[(-n )?-o RequestTTY=no -P mytag\] DEST=\[root@prod01\.example\.com\]')"
  assert_ge "${total_ssh_calls}" 7 "at least 7 remote ssh calls with -P mytag"
  assert_eq "${total_ssh_calls}" "${matching_ssh_calls}" "every ssh call forwards -P mytag"

  setup_case "regression_tag_p_missing_val" "dropin"
  run_bw_keysetup -P
  assert_eq "1" "${RUN_RC}" "-P without value exits 1"
  assert_contains "${RUN_STDERR}" "Option -P requires a value." "stderr reports missing -P value"
}

run_test test_happy_fresh_host_dropin_mode
run_test test_happy_hex_attachment_ids_supported
run_test test_happy_direct_sshd_config_edit_and_prose_preservation
run_test test_happy_authorized_keys_no_trailing_newline_and_dedup
run_test test_happy_su_fallback_when_runuser_absent
run_test test_happy_sshd_service_selection_and_include_variants
run_test test_happy_idempotent_rerun
run_test test_security_preflight_blocks_vault_mutation
run_test test_security_include_after_permitrootlogin_uses_direct_edit
run_test test_security_cp_failure_does_not_destroy_shadow_or_sshd_config
run_test test_security_pub_upload_failure_reverts_priv_and_orphan_pub_rejected
run_test test_security_non_login_item_rejected_in_checkPassLen
run_test test_security_jumper_nologin_shell_rejected
run_test test_security_jumper_symlink_attack_rejected
run_test test_security_malicious_pubkey_rejected_before_ssh
run_test test_security_sshd_case_insensitive_and_equals
run_test test_security_sshd_effective_config_and_systemd_rollback
run_test test_security_sshd_tmp_cfg_cleaned_on_failure
run_test test_security_salt_validation_and_duplicate_rejection
run_test test_security_password_with_newline_regenerated
run_test test_security_private_key_uploaded_before_pub
run_test test_security_invalid_uuid_rejected
run_test test_security_runtime_dir_rejects_disk_and_symlink_ancestor
run_test test_signal_sigterm_cleans_up_tmp_dir
run_test test_boundary_short_password_regenerated
run_test test_boundary_salt_variants
run_test test_error_non_root_user
run_test test_error_cli_args_and_incompatible_flags
run_test test_error_item_search_fails_closed
run_test test_error_privkey_lookup_fails_closed
run_test test_error_pass_or_field_lookup_fails_closed
run_test test_error_bw_generate_fails_closed
run_test test_error_remote_shadow_rollback
run_test test_error_remote_sshd_t_fails_reverts
run_test test_error_attachment_upload_fails_cleans_tmp_dir
run_test test_regression_ssh_tag_option_p_accepted

printf '\ntest_bw_keysetup.sh summary: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  exit 1
fi
