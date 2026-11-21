#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW_SSH="${REPO_DIR}/bw.ssh"

DEFAULT_ITEM_UUID="11111111-1111-4111-8111-111111111111"
DEFAULT_PRIVKEY_UUID="22222222-2222-4222-8222-222222222222"

PASS_COUNT=0
FAIL_COUNT=0

TEST_ROOT="$(mktemp -d)"
RUNTIME_ROOT="$(mktemp -d -p /dev/shm bw_ssh_test_rt.XXXXXXXXXX)"
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

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail_msg "${label}: output lacks '${needle}'."
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

# Create an isolated mock environment with tmpfs runtime directory for one test case.
setup_case() {
  local name="$1"
  CASE_DIR="${TEST_ROOT}/${name}"
  MOCK_BIN="${CASE_DIR}/bin"
  RUNTIME_DIR="${RUNTIME_ROOT}/${name}"
  STATE_DIR="${CASE_DIR}/state"

  mkdir -p "${MOCK_BIN}" "${RUNTIME_DIR}" "${STATE_DIR}"
  chmod 700 "${RUNTIME_DIR}"

  # Default mock: bw.sess succeeds.
  cat > "${MOCK_BIN}/bw.sess" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "bw.sess $*" >> "${STATE_DIR}/calls.log"
exit "${MOCK_SESS_RC:-0}"
EOF

  # Default mock: bw.item.search returns a valid UUID.
  cat > "${MOCK_BIN}/bw.item.search" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\${STATE_DIR}/search.args"
printf '%s\n' "bw.item.search \$*" >> "\${STATE_DIR}/calls.log"
rc="\${MOCK_SEARCH_RC:-0}"
if [[ "\${rc}" -ne 0 ]]; then
  exit "\${rc}"
fi
if [[ "\${MOCK_SEARCH_EMPTY:-0}" -eq 1 ]]; then
  exit 0
fi
printf '%s\n' "\${MOCK_ITEM_ID:-${DEFAULT_ITEM_UUID}}"
EOF

  # Default mock: bw.item.privKeyID returns a valid UUID.
  cat > "${MOCK_BIN}/bw.item.privKeyID" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\${STATE_DIR}/privkey.args"
printf '%s\n' "bw.item.privKeyID \$*" >> "\${STATE_DIR}/calls.log"
rc="\${MOCK_PRIVKEY_RC:-0}"
if [[ "\${rc}" -ne 0 ]]; then
  exit "\${rc}"
fi
if [[ "\${MOCK_PRIVKEY_EMPTY:-0}" -eq 1 ]]; then
  exit 0
fi
printf '%s\n' "\${MOCK_PRIVKEY_ID:-${DEFAULT_PRIVKEY_UUID}}"
EOF

  # Default mock: bw.item.pass prints configured password.
  cat > "${MOCK_BIN}/bw.item.pass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/pass.args"
printf '%s\n' "bw.item.pass $*" >> "${STATE_DIR}/calls.log"
rc="${MOCK_PASS_RC:-0}"
if [[ "${rc}" -ne 0 ]]; then
  exit "${rc}"
fi
printf '%s\n' "${MOCK_PASSWORD:-test-secret-password}"
EOF

  # Default mock: bw handles attachment fetch.
  cat > "${MOCK_BIN}/bw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/bw.args"
printf '%s\n' "bw $*" >> "${STATE_DIR}/calls.log"
if [[ "${MOCK_BW_ATTACH_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_BW_ATTACH_RC}"
fi
printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----"
printf '%s\n' "MOCK-KEY-DATA"
printf '%s\n' "-----END OPENSSH PRIVATE KEY-----"
EOF

  # Default mock: ssh-agent simulates isolated ephemeral agent start and kill.
  cat > "${MOCK_BIN}/ssh-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "ssh-agent $*" >> "${STATE_DIR}/calls.log"
if [[ "${1:-}" == "-s" ]]; then
  if [[ "${MOCK_AGENT_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_AGENT_RC}"
  fi
  printf 'SSH_AUTH_SOCK=%s/ephemeral.sock; export SSH_AUTH_SOCK;\n' "${STATE_DIR}"
  printf 'SSH_AGENT_PID=42424; export SSH_AGENT_PID;\n'
  printf 'echo Agent pid 42424;\n'
  exit 0
elif [[ "${1:-}" == "-k" ]]; then
  printf '%s\n' "${SSH_AGENT_PID:-}" > "${STATE_DIR}/agent.killed_pid"
  printf 'unset SSH_AUTH_SOCK;\nunset SSH_AGENT_PID;\n'
  exit 0
fi
exit 1
EOF

  # Default mock: ssh-add records arguments, agent socket, and stdin.
  cat > "${MOCK_BIN}/ssh-add" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/ssh_add.args"
printf '%s' "${SSH_AUTH_SOCK:-}" > "${STATE_DIR}/ssh_add.sock"
cat > "${STATE_DIR}/ssh_add.stdin"
printf '%s\n' "ssh-add $*" >> "${STATE_DIR}/calls.log"
exit "${MOCK_SSH_ADD_RC:-0}"
EOF

  # Default mock: ssh handles -G and execution modes.
  cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-G" ]]; then
  if [[ "${MOCK_SSH_G_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_SSH_G_RC}"
  fi
  if [[ -n "${MOCK_SSH_G_OUT+x}" ]]; then
    printf '%s\n' "${MOCK_SSH_G_OUT}"
  else
    printf 'user alice\nhost web01\nhostname 10.0.0.10\n'
  fi
  exit 0
fi

printf '%s\n' "ssh" >> "${STATE_DIR}/calls.log"
printf '%s\0' "$@" > "${STATE_DIR}/ssh.argv0"
printf '%s' "${SSH_AUTH_SOCK:-}" > "${STATE_DIR}/ssh.sock"
printf '%s' "${SSH_ASKPASS:-}" > "${STATE_DIR}/ssh.askpass"
printf '%s' "${SSH_ASKPASS_REQUIRE:-}" > "${STATE_DIR}/ssh.askpass_require"

if [[ "${MOCK_SSH_MODE:-normal}" == "askpass_check" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  stat -c '%a' "${tmp_dir}" > "${STATE_DIR}/perm.dir"
  stat -c '%a' "${tmp_dir}/pass" > "${STATE_DIR}/perm.pass"
  stat -c '%a' "${SSH_ASKPASS}" > "${STATE_DIR}/perm.askpass"
  printf '%s' "${tmp_dir}" > "${STATE_DIR}/askpass.dir"

  # Non-password prompt must fail and keep pass_file intact.
  rc_hostkey=0
  bash "${SSH_ASKPASS}" "Are you sure you want to continue connecting (yes/no/[fingerprint])?" > "${STATE_DIR}/askpass.hostkey" 2>/dev/null || rc_hostkey=$?
  printf '%s' "${rc_hostkey}" > "${STATE_DIR}/askpass.hostkey_rc"

  rc_empty=0
  bash "${SSH_ASKPASS}" "" > "${STATE_DIR}/askpass.empty" 2>/dev/null || rc_empty=$?
  printf '%s' "${rc_empty}" > "${STATE_DIR}/askpass.empty_rc"

  if [[ -f "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_reject"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_reject"
  fi

  # First password prompt succeeds and deletes pass_file.
  rc_call1=0
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/askpass.call1" 2>/dev/null || rc_call1=$?
  printf '%s' "${rc_call1}" > "${STATE_DIR}/askpass.call1_rc"

  if [[ -e "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_call1"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_call1"
  fi

  # Second password prompt must fail (single-use).
  rc_call2=0
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/askpass.call2" 2>/dev/null || rc_call2=$?
  printf '%s' "${rc_call2}" > "${STATE_DIR}/askpass.call2_rc"
elif [[ "${MOCK_SSH_MODE:-normal}" == "askpass_passcode" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  rc_pc=0
  bash "${SSH_ASKPASS}" "Enter PASSCODE:" > "${STATE_DIR}/askpass.passcode" 2>/dev/null || rc_pc=$?
  printf '%s' "${rc_pc}" > "${STATE_DIR}/askpass.passcode_rc"
  if [[ -e "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_passcode"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_passcode"
  fi
elif [[ "${MOCK_SSH_MODE:-normal}" == "sleep_ready" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  printf '%s\n' "${tmp_dir}" > "${STATE_DIR}/ready.dir"
  sleep 30
elif [[ "${MOCK_SSH_MODE:-normal}" == "record_dir" ]]; then
  dirname "${SSH_ASKPASS}" > "${STATE_DIR}/askpass.dir"
fi

if [[ -n "${MOCK_SSH_STDOUT:-}" ]]; then
  printf '%s\n' "${MOCK_SSH_STDOUT}"
fi
exit "${MOCK_SSH_RC:-0}"
EOF

  chmod +x \
    "${MOCK_BIN}/bw.sess" \
    "${MOCK_BIN}/bw.item.search" \
    "${MOCK_BIN}/bw.item.privKeyID" \
    "${MOCK_BIN}/bw.item.pass" \
    "${MOCK_BIN}/bw" \
    "${MOCK_BIN}/ssh-agent" \
    "${MOCK_BIN}/ssh-add" \
    "${MOCK_BIN}/ssh"
}

run_bw_ssh() {
  local out_file="${STATE_DIR}/stdout"
  local err_file="${STATE_DIR}/stderr"
  RUN_RC=0
  PATH="${MOCK_BIN}:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="${CUSTOM_RUNTIME_DIR-${RUNTIME_DIR}}" \
    STATE_DIR="${STATE_DIR}" \
    "${BW_SSH}" "$@" >"${out_file}" 2>"${err_file}" || RUN_RC=$?
  RUN_STDOUT="$(cat "${out_file}")"
  RUN_STDERR="$(cat "${err_file}")"
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

test_happy_privkey_auth() {
  setup_case "happy_privkey"
  MOCK_SSH_STDOUT="remote-command-output" \
    run_bw_ssh -p 2222 -J bastion alice@web01 "echo 'hello world'" "arg with spaces"

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "remote-command-output" "${RUN_STDOUT}" "clean stdout"
  assert_eq "" "${RUN_STDERR}" "empty stderr on key auth"
  assert_eq "get attachment ${DEFAULT_PRIVKEY_UUID} --itemid ${DEFAULT_ITEM_UUID} --raw" "$(cat "${STATE_DIR}/bw.args")" "bw get attachment args"
  assert_eq "-t 15 -" "$(cat "${STATE_DIR}/ssh_add.args")" "ssh-add args"
  assert_contains "$(cat "${STATE_DIR}/ssh_add.stdin")" "MOCK-KEY-DATA" "ssh-add received key"

  local -a recorded_args=()
  mapfile -d '' -t recorded_args < "${STATE_DIR}/ssh.argv0"
  assert_eq "7" "${#recorded_args[@]}" "preserved arg count"
  assert_eq "-p" "${recorded_args[0]}" "arg 0"
  assert_eq "2222" "${recorded_args[1]}" "arg 1"
  assert_eq "-J" "${recorded_args[2]}" "arg 2"
  assert_eq "bastion" "${recorded_args[3]}" "arg 3"
  assert_eq "alice@web01" "${recorded_args[4]}" "arg 4"
  assert_eq "echo 'hello world'" "${recorded_args[5]}" "arg 5 with quotes"
  assert_eq "arg with spaces" "${recorded_args[6]}" "arg 6 with spaces"
}

test_happy_password_fallback() {
  setup_case "happy_password"
  local secret="s3cr3t!pass'with\"chars&more"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_check" \
    MOCK_SSH_STDOUT="only-remote-stdout" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "only-remote-stdout" "${RUN_STDOUT}" "stdout contains only remote output"
  assert_contains "${RUN_STDERR}" "Using password authentication for alice@web01." "status message on stderr"
  assert_eq "force" "$(cat "${STATE_DIR}/ssh.askpass_require")" "SSH_ASKPASS_REQUIRE"
  assert_eq "700" "$(cat "${STATE_DIR}/perm.dir")" "temp dir mode 0700"
  assert_eq "600" "$(cat "${STATE_DIR}/perm.pass")" "pass file mode 0600"
  assert_eq "700" "$(cat "${STATE_DIR}/perm.askpass")" "askpass script mode 0700"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.call1_rc")" "first password prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.call1")" "first askpass call emits password"

  local created_dir
  created_dir="$(cat "${STATE_DIR}/askpass.dir")"
  assert_file_not_exists "${created_dir}" "temp dir removed on exit"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_happy_password_fallback_forwards_exit_code() {
  setup_case "happy_password_rc42"
  MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    MOCK_SSH_RC=42 \
    run_bw_ssh alice@web01

  assert_eq "42" "${RUN_RC}" "forwarded ssh exit code 42"
  assert_file_not_exists "$(cat "${STATE_DIR}/askpass.dir")" "temp dir removed on non-zero ssh exit"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_happy_ssh_g_hostname_fallback() {
  setup_case "happy_hostname_fallback"
  MOCK_SSH_G_OUT="$(printf 'user bob\nhostname db.example.com\n')" \
    MOCK_SSH_STDOUT="ok" \
    run_bw_ssh bob@db.example.com

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "bob@db.example.com" "$(cat "${STATE_DIR}/search.args")" "query built from hostname fallback"
  assert_eq "ok" "${RUN_STDOUT}" "clean stdout"
}

# --- Security regression tests ---

test_security_ephemeral_ssh_agent_isolated_and_killed() {
  setup_case "security_ephemeral_agent"
  SSH_AUTH_SOCK="/tmp/outer-shared-agent.sock" \
    SSH_AGENT_PID="99999" \
    MOCK_SSH_RC=42 \
    run_bw_ssh alice@web01

  assert_eq "42" "${RUN_RC}" "forwards ssh exit code without exec"
  assert_eq "${STATE_DIR}/ephemeral.sock" "$(cat "${STATE_DIR}/ssh_add.sock")" "ssh-add uses isolated agent"
  assert_eq "${STATE_DIR}/ephemeral.sock" "$(cat "${STATE_DIR}/ssh.sock")" "ssh uses isolated agent"
  assert_eq "42424" "$(cat "${STATE_DIR}/agent.killed_pid")" "ephemeral ssh-agent killed on exit"
  assert_contains "$(cat "${STATE_DIR}/calls.log")" "ssh-agent -s" "started ephemeral agent"
  assert_contains "$(cat "${STATE_DIR}/calls.log")" "ssh-agent -k" "stopped ephemeral agent"

  # Verify agent is also killed when ssh-add fails.
  setup_case "security_ephemeral_agent_add_fail"
  MOCK_SSH_ADD_RC=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 when ssh-add fails"
  assert_eq "42424" "$(cat "${STATE_DIR}/agent.killed_pid")" "ephemeral ssh-agent killed on ssh-add failure"
}

test_security_askpass_single_use_and_prompt_filtered() {
  setup_case "security_askpass_filter"
  local secret="s3cr3t-single-use-password"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_check" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_ne "0" "$(cat "${STATE_DIR}/askpass.hostkey_rc")" "rejects host-key confirmation prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.hostkey")" "host-key prompt leaks no password"
  assert_ne "0" "$(cat "${STATE_DIR}/askpass.empty_rc")" "rejects empty prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.empty")" "empty prompt leaks no password"
  assert_eq "yes" "$(cat "${STATE_DIR}/pass_exists_after_reject")" "rejected prompts keep pass_file"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.call1_rc")" "first password prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.call1")" "first password prompt returns secret"
  assert_eq "no" "$(cat "${STATE_DIR}/pass_exists_after_call1")" "first password prompt deletes pass_file"
  assert_ne "0" "$(cat "${STATE_DIR}/askpass.call2_rc")" "second password prompt fails"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.call2")" "second password prompt leaks no password"

  # Verify case-insensitive passcode prompt is also accepted once.
  setup_case "security_askpass_passcode"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_passcode" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "passcode run exit code"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.passcode_rc")" "passcode prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.passcode")" "passcode prompt returns secret"
  assert_eq "no" "$(cat "${STATE_DIR}/pass_exists_after_passcode")" "passcode prompt deletes pass_file"
}

test_security_password_auth_disables_control_master() {
  setup_case "security_control_master"
  MOCK_PRIVKEY_RC=2 run_bw_ssh -p 2222 alice@web01

  assert_eq "0" "${RUN_RC}" "exit code"
  local -a recorded_args=()
  mapfile -d '' -t recorded_args < "${STATE_DIR}/ssh.argv0"
  assert_eq "7" "${#recorded_args[@]}" "includes ControlMaster and ControlPersist disable flags"
  assert_eq "-o" "${recorded_args[0]}" "arg 0"
  assert_eq "ControlMaster=no" "${recorded_args[1]}" "arg 1"
  assert_eq "-o" "${recorded_args[2]}" "arg 2"
  assert_eq "ControlPersist=no" "${recorded_args[3]}" "arg 3"
  assert_eq "-p" "${recorded_args[4]}" "arg 4"
  assert_eq "2222" "${recorded_args[5]}" "arg 5"
  assert_eq "alice@web01" "${recorded_args[6]}" "arg 6"
}

test_security_runtime_dir_validation() {
  # Disk-backed (non-tmpfs) XDG_RUNTIME_DIR under TEST_ROOT must fall back to /dev/shm.
  setup_case "security_rt_disk"
  local disk_dir="${CASE_DIR}/disk_runtime"
  mkdir -p "${disk_dir}"
  chmod 700 "${disk_dir}"

  CUSTOM_RUNTIME_DIR="${disk_dir}" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "falls back on disk-backed XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of disk"
  assert_dir_empty "${disk_dir}" "disk dir never used"

  # Symlink XDG_RUNTIME_DIR pointing to tmpfs must be rejected and fall back to /dev/shm.
  setup_case "security_rt_symlink"
  local link_dir="${RUNTIME_ROOT}/symlink_rt"
  ln -s "${RUNTIME_DIR}" "${link_dir}"

  CUSTOM_RUNTIME_DIR="${link_dir}" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  rm -f "${link_dir}"
  assert_eq "0" "${RUN_RC}" "falls back on symlink XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of symlink"
  assert_dir_empty "${RUNTIME_DIR}" "symlink target never used"

  # Relative XDG_RUNTIME_DIR must be rejected and fall back to /dev/shm.
  setup_case "security_rt_relative"
  CUSTOM_RUNTIME_DIR="relative/runtime" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "falls back on relative XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of relative path"

  # Fail closed when neither XDG_RUNTIME_DIR nor /dev/shm is tmpfs/ramfs.
  setup_case "security_rt_no_tmpfs"
  cat > "${MOCK_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
printf 'ext4\n'
EOF
  chmod +x "${MOCK_BIN}/stat"

  MOCK_PRIVKEY_RC=2 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "fails closed when no tmpfs runtime dir exists"
  assert_contains "${RUN_STDERR}" "No writable RAM-backed runtime directory" "reports missing RAM-backed dir"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked when no tmpfs exists"
}

test_security_invalid_uuid_rejected() {
  setup_case "security_bad_item_uuid"
  MOCK_ITEM_ID="item-123" run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "rejects non-UUID itemID"
  assert_contains "${RUN_STDERR}" "invalid UUID" "stderr reports invalid item UUID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on bad itemID"

  setup_case "security_bad_privkey_uuid"
  MOCK_PRIVKEY_ID="att-priv-1" run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "rejects non-UUID privkeyID"
  assert_contains "${RUN_STDERR}" "invalid UUID" "stderr reports invalid privkey UUID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on bad privkeyID"
}

# --- Boundary and error paths ---

test_error_zero_args() {
  setup_case "error_zero_args"
  run_bw_ssh

  assert_eq "1" "${RUN_RC}" "exit code 1 on zero args"
  assert_eq "" "${RUN_STDOUT}" "empty stdout"
  assert_contains "${RUN_STDERR}" "Usage:" "usage on stderr"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_bw_sess_fails() {
  setup_case "error_bw_sess"
  MOCK_SESS_RC=1 run_bw_ssh alice@web01

  assert_ne "0" "${RUN_RC}" "non-zero exit when bw.sess fails"
  assert_contains "${RUN_STDERR}" "bw.sess failed" "stderr reports bw.sess failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_ssh_g_fails() {
  setup_case "error_ssh_g_fails"
  MOCK_SSH_G_RC=255 run_bw_ssh alice@web01

  assert_ne "0" "${RUN_RC}" "non-zero exit when ssh -G fails"
  assert_contains "${RUN_STDERR}" "ssh -G failed" "stderr reports ssh -G failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_ssh_g_missing_user() {
  setup_case "error_ssh_g_no_user"
  MOCK_SSH_G_OUT="host web01" run_bw_ssh web01

  assert_ne "0" "${RUN_RC}" "non-zero exit when user is empty"
  assert_contains "${RUN_STDERR}" "lacks user or host" "stderr reports missing user"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_ssh_g_missing_host() {
  setup_case "error_ssh_g_no_host"
  MOCK_SSH_G_OUT="user alice" run_bw_ssh alice

  assert_ne "0" "${RUN_RC}" "non-zero exit when host and hostname are empty"
  assert_contains "${RUN_STDERR}" "lacks user or host" "stderr reports missing host"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_item_search_fails() {
  local rc
  for rc in 1 2 3; do
    setup_case "error_search_rc_${rc}"
    MOCK_SEARCH_RC="${rc}" run_bw_ssh alice@web01
    assert_eq "${rc}" "${RUN_RC}" "propagates bw.item.search exit ${rc}"
    assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on search exit ${rc}"
  done

  setup_case "error_search_empty"
  MOCK_SEARCH_EMPTY=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 on empty search ID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on empty search ID"
}

test_error_privkey_fails_closed() {
  local rc
  for rc in 1 3; do
    setup_case "error_privkey_rc_${rc}"
    MOCK_PRIVKEY_RC="${rc}" run_bw_ssh alice@web01
    assert_eq "${rc}" "${RUN_RC}" "propagates privKeyID exit ${rc}"
    assert_file_not_exists "${STATE_DIR}/pass.args" "does not fall back to password on exit ${rc}"
    assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on exit ${rc}"
  done

  setup_case "error_privkey_empty"
  MOCK_PRIVKEY_EMPTY=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 on empty privKeyID"
  assert_file_not_exists "${STATE_DIR}/pass.args" "does not fall back to password on empty privKeyID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on empty privKeyID"
}

test_error_bw_get_attachment_fails_pipefail() {
  setup_case "error_bw_attach_pipefail"
  MOCK_BW_ATTACH_RC=1 MOCK_SSH_ADD_RC=0 run_bw_ssh alice@web01

  assert_eq "1" "${RUN_RC}" "pipefail catches bw get attachment failure"
  assert_contains "${RUN_STDERR}" "Cannot load private key" "stderr reports key load failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_ssh_add_fails() {
  setup_case "error_ssh_add_fails"
  MOCK_BW_ATTACH_RC=0 MOCK_SSH_ADD_RC=1 run_bw_ssh alice@web01

  assert_eq "1" "${RUN_RC}" "exits 1 when ssh-add fails"
  assert_contains "${RUN_STDERR}" "Cannot load private key" "stderr reports key load failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_bw_item_pass_fails() {
  setup_case "error_pass_fails"
  MOCK_PRIVKEY_RC=2 MOCK_PASS_RC=1 run_bw_ssh alice@web01

  assert_eq "1" "${RUN_RC}" "exits 1 when bw.item.pass fails"
  assert_contains "${RUN_STDERR}" "Cannot fetch password" "stderr reports password fetch failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
  assert_dir_empty "${RUNTIME_DIR}" "no temp dir created"
}

test_error_ssh_fails_immediately_without_askpass() {
  setup_case "error_ssh_255_no_askpass"
  MOCK_PRIVKEY_RC=2 MOCK_SSH_MODE="record_dir" MOCK_SSH_RC=255 run_bw_ssh alice@web01

  assert_eq "255" "${RUN_RC}" "forwards ssh exit 255"
  assert_file_not_exists "$(cat "${STATE_DIR}/askpass.dir")" "temp dir removed after immediate ssh failure"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_signal_sigterm_cleans_up_tmp_dir() {
  setup_case "signal_sigterm"
  local bg_pid=0
  local wait_i=0
  local tmp_dir=""
  local sig_rc=0

  # Start bw.ssh in its own session so SIGTERM reaches both bw.ssh and ssh.
  PATH="${MOCK_BIN}:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
    STATE_DIR="${STATE_DIR}" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="sleep_ready" \
    setsid "${BW_SSH}" alice@web01 >"${STATE_DIR}/stdout" 2>"${STATE_DIR}/stderr" &
  bg_pid=$!

  while [[ ! -s "${STATE_DIR}/ready.dir" && "${wait_i}" -lt 50 ]]; do
    sleep 0.1
    wait_i=$((wait_i + 1))
  done

  if [[ ! -s "${STATE_DIR}/ready.dir" ]]; then
    kill -KILL -- -"${bg_pid}" 2>/dev/null || true
    fail_msg "mock ssh did not start in time."
    return 1
  fi

  tmp_dir="$(cat "${STATE_DIR}/ready.dir")"
  if [[ ! -d "${tmp_dir}" ]]; then
    kill -KILL -- -"${bg_pid}" 2>/dev/null || true
    fail_msg "expected temp dir to exist while ssh runs."
    return 1
  fi

  kill -TERM -- -"${bg_pid}" 2>/dev/null || true
  wait "${bg_pid}" || sig_rc=$?

  assert_ne "0" "${sig_rc}" "non-zero exit after SIGTERM"
  assert_file_not_exists "${tmp_dir}" "temp dir removed on SIGTERM"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean after SIGTERM"
}

test_runtime_dir_fallback_to_dev_shm() {
  setup_case "runtime_fallback_missing"
  CUSTOM_RUNTIME_DIR="${RUNTIME_ROOT}/does-not-exist" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "exit 0 with missing XDG_RUNTIME_DIR"
  local shm_dir
  shm_dir="$(cat "${STATE_DIR}/askpass.dir")"
  assert_contains "${shm_dir}" "/dev/shm/bw_ssh." "fell back to /dev/shm"
  assert_file_not_exists "${shm_dir}" "removed /dev/shm temp dir on exit"

  setup_case "runtime_fallback_unwritable"
  local ro_dir="${RUNTIME_ROOT}/readonly_runtime"
  mkdir -p "${ro_dir}"
  chmod 500 "${ro_dir}"

  CUSTOM_RUNTIME_DIR="${ro_dir}" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  chmod 700 "${ro_dir}"
  assert_eq "0" "${RUN_RC}" "exit 0 with unwritable XDG_RUNTIME_DIR"
  shm_dir="$(cat "${STATE_DIR}/askpass.dir")"
  assert_contains "${shm_dir}" "/dev/shm/bw_ssh." "fell back to /dev/shm on unwritable dir"
  assert_file_not_exists "${shm_dir}" "removed /dev/shm temp dir on exit"
}

run_test test_happy_privkey_auth
run_test test_happy_password_fallback
run_test test_happy_password_fallback_forwards_exit_code
run_test test_happy_ssh_g_hostname_fallback
run_test test_security_ephemeral_ssh_agent_isolated_and_killed
run_test test_security_askpass_single_use_and_prompt_filtered
run_test test_security_password_auth_disables_control_master
run_test test_security_runtime_dir_validation
run_test test_security_invalid_uuid_rejected
run_test test_error_zero_args
run_test test_error_bw_sess_fails
run_test test_error_ssh_g_fails
run_test test_error_ssh_g_missing_user
run_test test_error_ssh_g_missing_host
run_test test_error_item_search_fails
run_test test_error_privkey_fails_closed
run_test test_error_bw_get_attachment_fails_pipefail
run_test test_error_ssh_add_fails
run_test test_error_bw_item_pass_fails
run_test test_error_ssh_fails_immediately_without_askpass
run_test test_signal_sigterm_cleans_up_tmp_dir
run_test test_runtime_dir_fallback_to_dev_shm

printf '\ntest_bw_ssh.sh summary: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  exit 1
fi
