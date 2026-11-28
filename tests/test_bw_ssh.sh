#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW_SSH="${REPO_DIR}/bw.ssh"

DEFAULT_ITEM_UUID="11111111-1111-4111-8111-111111111111"
DEFAULT_PRIVKEY_UUID="22222222-2222-4222-8222-222222222222"

PASS_COUNT=0
FAIL_COUNT=0

TEST_ROOT="$(mktemp -d)"
RUNTIME_ROOT="$(mktemp -d "/dev/shm/bw_ssh_test_rt.XXXXXXXXXX")"

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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    fail_msg "${label}: output must not contain '${needle}'."
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

# Create an isolated mock environment with a tmpfs runtime directory.
setup_case() {
  local name="$1"
  CASE_DIR="${TEST_ROOT}/${name}"
  MOCK_BIN="${CASE_DIR}/bin"
  RUNTIME_DIR="${RUNTIME_ROOT}/${name}"
  STATE_DIR="${CASE_DIR}/state"

  mkdir -p "${MOCK_BIN}" "${RUNTIME_DIR}" "${STATE_DIR}"
  chmod 700 "${RUNTIME_DIR}"

  # Default mock: bw.sess exits 0.
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

  # Default mock: bw.item.privKeyID returns a valid attachment ID.
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

  # Default mock: bw.item.pass prints the configured password.
  cat > "${MOCK_BIN}/bw.item.pass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/pass.args"
printf '%s\n' "bw.item.pass $*" >> "${STATE_DIR}/calls.log"
rc="${MOCK_PASS_RC:-0}"
if [[ "${rc}" -ne 0 ]]; then
  exit "${rc}"
fi
if [[ "${MOCK_PASS_EMPTY:-0}" -eq 1 ]]; then
  exit 0
fi
printf '%s\n' "${MOCK_PASSWORD:-test-secret-password}"
EOF

  # Default mock: bw handles attachment download.
  cat > "${MOCK_BIN}/bw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/bw.args"
printf '%s\n' "bw $*" >> "${STATE_DIR}/calls.log"
if [[ "${MOCK_BW_ATTACH_RC:-0}" -ne 0 ]]; then
  exit "${MOCK_BW_ATTACH_RC}"
fi
if [[ "${MOCK_BW_ATTACH_EMPTY:-0}" -eq 1 ]]; then
  exit 0
fi
if [[ -n "${MOCK_BW_ATTACH_FILE:-}" ]]; then
  cat "${MOCK_BW_ATTACH_FILE}"
  exit 0
fi
printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----"
printf '%s\n' "MOCK-KEY-DATA"
printf '%s\n' "-----END OPENSSH PRIVATE KEY-----"
EOF

  # Default mock: ssh-agent simulates ephemeral agent start and stop.
  cat > "${MOCK_BIN}/ssh-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "ssh-agent $*" >> "${STATE_DIR}/calls.log"
if [[ "${1:-}" == "-s" ]]; then
  if [[ "${MOCK_AGENT_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_AGENT_RC}"
  fi
  if [[ "${MOCK_AGENT_EMPTY:-0}" -eq 1 ]]; then
    exit 0
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

  # Default mock: ssh-add records arguments, socket, and stdin.
  cat > "${MOCK_BIN}/ssh-add" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${STATE_DIR}/ssh_add.args"
printf '%s' "${SSH_AUTH_SOCK:-}" > "${STATE_DIR}/ssh_add.sock"
cat > "${STATE_DIR}/ssh_add.stdin"
printf '%s\n' "ssh-add $*" >> "${STATE_DIR}/calls.log"
exit "${MOCK_SSH_ADD_RC:-0}"
EOF

  # Default mock: ssh emits real ssh -G keys (user, hostname) and records calls.
  cat > "${MOCK_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_SSH_REAL_G:-0}" -eq 1 && "${1:-}" == "-G" ]]; then
  exec /usr/bin/ssh "$@"
fi

if [[ "${1:-}" == "-G" ]]; then
  if [[ "${MOCK_SSH_G_RC:-0}" -ne 0 ]]; then
    exit "${MOCK_SSH_G_RC}"
  fi
  if [[ -n "${MOCK_SSH_G_OUT+x}" ]]; then
    printf '%s\n' "${MOCK_SSH_G_OUT}"
  else
    printf 'user alice\nhostname web01\n'
  fi
  exit 0
fi

printf '%s\n' "ssh" >> "${STATE_DIR}/calls.log"
printf '%s\0' "$@" > "${STATE_DIR}/ssh.argv0"
printf '%s' "${SSH_AUTH_SOCK:-}" > "${STATE_DIR}/ssh.sock"
printf '%s' "${SSH_AGENT_PID:-}" > "${STATE_DIR}/ssh.agent_pid"
printf '%s' "${SSH_ASKPASS:-}" > "${STATE_DIR}/ssh.askpass"
printf '%s' "${SSH_ASKPASS_REQUIRE:-}" > "${STATE_DIR}/ssh.askpass_require"

if [[ "${MOCK_SSH_MODE:-normal}" == "askpass_check" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  stat -c '%a' "${tmp_dir}" > "${STATE_DIR}/perm.dir"
  stat -c '%a' "${tmp_dir}/pass" > "${STATE_DIR}/perm.pass"
  stat -c '%a' "${SSH_ASKPASS}" > "${STATE_DIR}/perm.askpass"
  printf '%s' "${tmp_dir}" > "${STATE_DIR}/askpass.dir"

  # Run non-password prompt without a controlling terminal so /dev/tty is absent.
  rc_hostkey=0
  setsid -w bash "${SSH_ASKPASS}" "Are you sure you want to continue connecting (yes/no/[fingerprint])?" < /dev/null > "${STATE_DIR}/askpass.hostkey" 2> "${STATE_DIR}/askpass.hostkey_err" || rc_hostkey=$?
  printf '%s' "${rc_hostkey}" > "${STATE_DIR}/askpass.hostkey_rc"

  rc_keystone_hostkey=0
  setsid -w bash "${SSH_ASKPASS}" "The authenticity of host 'keystone' can't be established." < /dev/null > "${STATE_DIR}/askpass.keystone_hostkey" 2> "${STATE_DIR}/askpass.keystone_hostkey_err" || rc_keystone_hostkey=$?
  printf '%s' "${rc_keystone_hostkey}" > "${STATE_DIR}/askpass.keystone_hostkey_rc"

  rc_empty=0
  bash "${SSH_ASKPASS}" "" > "${STATE_DIR}/askpass.empty" 2> "${STATE_DIR}/askpass.empty_err" || rc_empty=$?
  printf '%s' "${rc_empty}" > "${STATE_DIR}/askpass.empty_rc"

  rc_passphrase=0
  bash "${SSH_ASKPASS}" "Enter passphrase for key '/home/alice/.ssh/password_key':" > "${STATE_DIR}/askpass.passphrase" 2> "${STATE_DIR}/askpass.passphrase_err" || rc_passphrase=$?
  printf '%s' "${rc_passphrase}" > "${STATE_DIR}/askpass.passphrase_rc"

  rc_keypw=0
  bash "${SSH_ASKPASS}" "Enter KEY password:" > "${STATE_DIR}/askpass.keypw" 2> "${STATE_DIR}/askpass.keypw_err" || rc_keypw=$?
  printf '%s' "${rc_keypw}" > "${STATE_DIR}/askpass.keypw_rc"

  rc_pwforkey=0
  bash "${SSH_ASKPASS}" "Enter password for key '/tmp/id':" > "${STATE_DIR}/askpass.pwforkey" 2> "${STATE_DIR}/askpass.pwforkey_err" || rc_pwforkey=$?
  printf '%s' "${rc_pwforkey}" > "${STATE_DIR}/askpass.pwforkey_rc"

  rc_keyspw=0
  bash "${SSH_ASKPASS}" "Enter key's password:" > "${STATE_DIR}/askpass.keyspw" 2> "${STATE_DIR}/askpass.keyspw_err" || rc_keyspw=$?
  printf '%s' "${rc_keyspw}" > "${STATE_DIR}/askpass.keyspw_rc"

  if [[ -f "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_reject"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_reject"
  fi

  # First password prompt succeeds and deletes pass_file.
  rc_call1=0
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/askpass.call1" 2> "${STATE_DIR}/askpass.call1_err" || rc_call1=$?
  printf '%s' "${rc_call1}" > "${STATE_DIR}/askpass.call1_rc"

  if [[ -e "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_call1"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_call1"
  fi

  # Second password prompt fails because askpass is single-use.
  rc_call2=0
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/askpass.call2" 2> "${STATE_DIR}/askpass.call2_err" || rc_call2=$?
  printf '%s' "${rc_call2}" > "${STATE_DIR}/askpass.call2_rc"
elif [[ "${MOCK_SSH_MODE:-normal}" == "askpass_prompt" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  rc_prompt=0
  setsid -w bash "${SSH_ASKPASS}" "${MOCK_ASKPASS_PROMPT}" < /dev/null > "${STATE_DIR}/askpass.prompt_out" 2> "${STATE_DIR}/askpass.prompt_err" || rc_prompt=$?
  printf '%s' "${rc_prompt}" > "${STATE_DIR}/askpass.prompt_rc"
  if [[ -e "${tmp_dir}/pass" ]]; then
    printf 'yes' > "${STATE_DIR}/pass_exists_after_prompt"
  else
    printf 'no' > "${STATE_DIR}/pass_exists_after_prompt"
  fi
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
elif [[ "${MOCK_SSH_MODE:-normal}" == "askpass_race" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/race.out1" 2>/dev/null &
  pid1=$!
  bash "${SSH_ASKPASS}" "alice@web01's password:" > "${STATE_DIR}/race.out2" 2>/dev/null &
  pid2=$!
  rc1=0
  rc2=0
  wait "${pid1}" || rc1=$?
  wait "${pid2}" || rc2=$?
  printf '%s' "${rc1}" > "${STATE_DIR}/race.rc1"
  printf '%s' "${rc2}" > "${STATE_DIR}/race.rc2"
  find "${tmp_dir}" -name 'pass*' > "${STATE_DIR}/race.leftover"
elif [[ "${MOCK_SSH_MODE:-normal}" == "askpass_tty" ]]; then
  python3 - "${SSH_ASKPASS}" "${STATE_DIR}/askpass.tty_out" "${STATE_DIR}/askpass.tty_rc" "${MOCK_ASKPASS_PROMPT:-Are you sure you want to continue connecting (yes/no/[fingerprint])? }" <<'PYEOF'
import os, pty, select, subprocess, sys

script, out_path, rc_path, prompt_text = sys.argv[1:5]
master_fd, slave_fd = pty.openpty()

def child_setup():
    os.setsid()
    import fcntl, termios
    fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(
    ["bash", script, prompt_text],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=slave_fd,
    pass_fds=(slave_fd,),
    preexec_fn=child_setup,
)
os.close(slave_fd)

# Wait for prompt on the pty, then reply "no\n".
rlist, _, _ = select.select([master_fd], [], [], 5.0)
if rlist:
    os.read(master_fd, 4096)
    os.write(master_fd, b"no\n")

stdout_data, _ = proc.communicate(timeout=5)
os.close(master_fd)
with open(out_path, "wb") as f:
    f.write(stdout_data)
with open(rc_path, "w") as f:
    f.write(str(proc.returncode))
PYEOF
elif [[ "${MOCK_SSH_MODE:-normal}" == "sleep_ready" ]]; then
  tmp_dir="$(dirname "${SSH_ASKPASS}")"
  printf '%s\n' "${tmp_dir}" > "${STATE_DIR}/ready.dir"
  sleep 30
elif [[ "${MOCK_SSH_MODE:-normal}" == "sleep_agent" ]]; then
  printf '%s\n' "${SSH_AGENT_PID:-}" > "${STATE_DIR}/ready.agent_pid"
  sleep 30
elif [[ "${MOCK_SSH_MODE:-normal}" == "record_dir" ]]; then
  dirname "${SSH_ASKPASS}" > "${STATE_DIR}/askpass.dir"
elif [[ "${MOCK_SSH_MODE:-normal}" == "real_agent_list" ]]; then
  /usr/bin/ssh-add -L > "${STATE_DIR}/agent.keys"
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

test_happy_hex_attachment_id_accepted() {
  setup_case "happy_hex_att_id"
  MOCK_PRIVKEY_ID="a1b2c3d4" \
    MOCK_SSH_STDOUT="hex-ok" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "accepts 8-char hex attachment ID"
  assert_eq "hex-ok" "${RUN_STDOUT}" "clean stdout"
  assert_eq "get attachment a1b2c3d4 --itemid ${DEFAULT_ITEM_UUID} --raw" "$(cat "${STATE_DIR}/bw.args")" "uses 8-char attachment ID"
}

test_happy_info_flags_pass_through() {
  setup_case "happy_info_v"
  MOCK_SSH_STDOUT="OpenSSH_9.2p1" run_bw_ssh -V
  assert_eq "0" "${RUN_RC}" "-V exits 0"
  assert_eq "OpenSSH_9.2p1" "${RUN_STDOUT}" "-V prints ssh stdout"
  assert_file_not_exists "${STATE_DIR}/search.args" "-V skips bw.item.search"
  assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "-V skips bw.sess"

  setup_case "happy_info_g"
  MOCK_SSH_G_OUT="user alice" run_bw_ssh -G alice@web01
  assert_eq "0" "${RUN_RC}" "-G exits 0"
  assert_eq "user alice" "${RUN_STDOUT}" "-G passes straight to ssh"
  assert_file_not_exists "${STATE_DIR}/calls.log" "-G skips bw.sess and vault calls"

  setup_case "happy_info_q"
  MOCK_SSH_STDOUT="aes256-gcm@openssh.com" run_bw_ssh -Q cipher
  assert_eq "0" "${RUN_RC}" "-Q exits 0"
  assert_eq "aes256-gcm@openssh.com" "${RUN_STDOUT}" "-Q passes straight to ssh"
  assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "-Q skips bw.sess"

  # A -V flag after destination belongs to the remote command, not ssh.
  setup_case "happy_remote_cmd_v"
  MOCK_SSH_STDOUT="Python 3.11" run_bw_ssh alice@web01 python3 -V
  assert_eq "0" "${RUN_RC}" "remote -V exits 0"
  assert_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "remote -V still authenticates via vault"
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
  assert_file_not_exists "${created_dir}" "temp dir deleted on exit"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_happy_password_fallback_forwards_exit_code() {
  setup_case "happy_password_rc42"
  MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    MOCK_SSH_RC=42 \
    run_bw_ssh alice@web01

  assert_eq "42" "${RUN_RC}" "forwarded ssh exit code 42"
  assert_file_not_exists "$(cat "${STATE_DIR}/askpass.dir")" "temp dir deleted on non-zero ssh exit"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_happy_ssh_g_hostname_parsing() {
  setup_case "happy_hostname_parsing"
  MOCK_SSH_G_OUT="$(printf 'user bob\nhostname db.example.com\nproxyjump none\n')" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_STDOUT="ok" \
    run_bw_ssh bob@db.example.com

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "bob@db.example.com" "$(cat "${STATE_DIR}/search.args")" "query built from user and hostname"
  assert_eq "ok" "${RUN_STDOUT}" "clean stdout"
}

# --- Real integration test with system ssh -G, ssh-agent, and ssh-add ---

test_integration_real_ssh_g_and_real_ssh_agent() {
  setup_case "integration_real_ssh"
  # Remove mocked ssh-agent and ssh-add so real OpenSSH binaries execute.
  rm -f "${MOCK_BIN}/ssh-agent" "${MOCK_BIN}/ssh-add"

  local key_file="${CASE_DIR}/id_ed25519"
  local ssh_cfg="${CASE_DIR}/ssh_config"
  ssh-keygen -t ed25519 -f "${key_file}" -N "" -C "alice@192.0.2.55" >/dev/null
  cat > "${ssh_cfg}" <<'EOF'
Host webalias
  User alice
  Hostname 192.0.2.55
EOF

  local expected_pub
  expected_pub="$(cat "${key_file}.pub")"

  MOCK_SSH_REAL_G=1 \
    MOCK_BW_ATTACH_FILE="${key_file}" \
    MOCK_SSH_MODE="real_agent_list" \
    run_bw_ssh -F "${ssh_cfg}" webalias

  assert_eq "0" "${RUN_RC}" "real ssh -G and ssh-agent run exits 0"
  assert_eq "alice@192.0.2.55" "$(cat "${STATE_DIR}/search.args")" "real ssh -G resolves alias to hostname"
  assert_contains "$(cat "${STATE_DIR}/agent.keys")" "${expected_pub}" "real ssh-agent holds loaded Ed25519 key"

  local real_agent_pid real_agent_sock
  real_agent_pid="$(cat "${STATE_DIR}/ssh.agent_pid")"
  real_agent_sock="$(cat "${STATE_DIR}/ssh.sock")"
  assert_ne "" "${real_agent_pid}" "real ssh-agent PID recorded"
  if kill -0 "${real_agent_pid}" 2>/dev/null; then
    kill -TERM "${real_agent_pid}" 2>/dev/null || true
    fail_msg "real ephemeral ssh-agent process ${real_agent_pid} is still running after exit."
    return 1
  fi
  assert_file_not_exists "${real_agent_sock}" "real ssh-agent socket removed on exit"
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

  # Verify outer SSH_AGENT_PID is never killed if ssh-agent -s fails or returns empty output.
  setup_case "security_agent_start_fail"
  SSH_AUTH_SOCK="/tmp/outer.sock" \
    SSH_AGENT_PID="99999" \
    MOCK_AGENT_RC=1 \
    run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 when ssh-agent -s fails"
  assert_contains "${RUN_STDERR}" "Cannot start ssh-agent" "stderr reports ssh-agent failure"
  assert_file_not_exists "${STATE_DIR}/agent.killed_pid" "outer ssh-agent not killed on start failure"

  setup_case "security_agent_empty_env"
  SSH_AUTH_SOCK="/tmp/outer.sock" \
    SSH_AGENT_PID="99999" \
    MOCK_AGENT_EMPTY=1 \
    run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 when ssh-agent -s emits no variables"
  assert_contains "${RUN_STDERR}" "SSH_AUTH_SOCK and SSH_AGENT_PID" "stderr reports missing agent variables"
  assert_file_not_exists "${STATE_DIR}/agent.killed_pid" "outer ssh-agent not killed on empty agent output"
}

test_security_askpass_single_use_and_prompt_filtered() {
  setup_case "security_askpass_filter"
  local secret="s3cr3t-single-use-password"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_check" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.hostkey_rc")" "rejects host-key prompt without tty"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.hostkey")" "host-key prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.hostkey_err")" "host-key prompt without tty produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.keystone_hostkey_rc")" "rejects keystone host-key prompt without tty"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keystone_hostkey")" "keystone host-key prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keystone_hostkey_err")" "keystone host-key prompt without tty produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.empty_rc")" "rejects empty prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.empty")" "empty prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.empty_err")" "empty prompt produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.passphrase_rc")" "rejects passphrase prompt with password_key path"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.passphrase")" "passphrase prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.passphrase_err")" "passphrase prompt produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.keypw_rc")" "rejects KEY password prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keypw")" "KEY password prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keypw_err")" "KEY password prompt produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.pwforkey_rc")" "rejects password for key prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.pwforkey")" "password for key prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.pwforkey_err")" "password for key prompt produces empty stderr"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.keyspw_rc")" "rejects Enter key's password prompt"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keyspw")" "Enter key's password prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.keyspw_err")" "Enter key's password prompt produces empty stderr"
  assert_eq "yes" "$(cat "${STATE_DIR}/pass_exists_after_reject")" "rejected prompts keep pass_file"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.call1_rc")" "first password prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.call1")" "first password prompt returns secret"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.call1_err")" "first password prompt produces empty stderr"
  assert_eq "no" "$(cat "${STATE_DIR}/pass_exists_after_call1")" "first password prompt deletes pass_file"
  assert_eq "1" "$(cat "${STATE_DIR}/askpass.call2_rc")" "second password prompt fails"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.call2")" "second password prompt leaks no password"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.call2_err")" "second password prompt produces empty stderr"

  # Verify case-insensitive passcode prompt is accepted once.
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

test_security_askpass_atomic_race_and_tty_prompt() {
  setup_case "security_askpass_race"
  local secret="atomic-race-secret"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_race" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "race harness exits 0"
  local rc1 rc2 out1 out2 wins=0
  rc1="$(cat "${STATE_DIR}/race.rc1")"
  rc2="$(cat "${STATE_DIR}/race.rc2")"
  out1="$(cat "${STATE_DIR}/race.out1")"
  out2="$(cat "${STATE_DIR}/race.out2")"
  if [[ "${rc1}" -eq 0 ]]; then
    wins=$((wins + 1))
    assert_eq "${secret}" "${out1}" "winner 1 receives secret"
    assert_eq "" "${out2}" "loser 2 receives empty output"
  fi
  if [[ "${rc2}" -eq 0 ]]; then
    wins=$((wins + 1))
    assert_eq "${secret}" "${out2}" "winner 2 receives secret"
    assert_eq "" "${out1}" "loser 1 receives empty output"
  fi
  assert_eq "1" "${wins}" "exactly one concurrent askpass caller succeeds"
  assert_eq "" "$(cat "${STATE_DIR}/race.leftover")" "no leftover pass files after race"

  # Verify interactive /dev/tty reply works for host-key confirmation.
  setup_case "security_askpass_tty"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_tty" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "tty harness exits 0"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.tty_rc")" "tty prompt exits 0"
  assert_eq "no" "$(cat "${STATE_DIR}/askpass.tty_out")" "tty prompt returns user reply without auto-accept"
}

test_security_password_auth_flags_and_proxyjump_rejection() {
  setup_case "security_password_flags"
  SSH_AUTH_SOCK="/tmp/outer-agent.sock" \
    MOCK_PRIVKEY_RC=2 \
    run_bw_ssh -p 2222 alice@web01

  assert_eq "0" "${RUN_RC}" "exit code"
  assert_eq "" "$(cat "${STATE_DIR}/ssh.sock")" "unsets SSH_AUTH_SOCK in password mode"

  local -a recorded_args=()
  mapfile -d '' -t recorded_args < "${STATE_DIR}/ssh.argv0"
  assert_eq "11" "${#recorded_args[@]}" "passes all hardening -o flags before user args"
  assert_eq "-o" "${recorded_args[0]}" "arg 0"
  assert_eq "PubkeyAuthentication=no" "${recorded_args[1]}" "arg 1"
  assert_eq "-o" "${recorded_args[2]}" "arg 2"
  assert_eq "ControlMaster=no" "${recorded_args[3]}" "arg 3"
  assert_eq "-o" "${recorded_args[4]}" "arg 4"
  assert_eq "ControlPersist=no" "${recorded_args[5]}" "arg 5"
  assert_eq "-o" "${recorded_args[6]}" "arg 6"
  assert_eq "ControlPath=none" "${recorded_args[7]}" "arg 7"
  assert_eq "-p" "${recorded_args[8]}" "arg 8"
  assert_eq "2222" "${recorded_args[9]}" "arg 9"
  assert_eq "alice@web01" "${recorded_args[10]}" "arg 10"

  # Reject ProxyJump in password fallback mode so SSH_ASKPASS cannot leak to a bastion.
  setup_case "security_proxyjump_rejected"
  MOCK_SSH_G_OUT="$(printf 'user alice\nhostname web01\nproxyjump bastion.example.com\n')" \
    MOCK_PRIVKEY_RC=2 \
    run_bw_ssh -J bastion.example.com alice@web01

  assert_eq "1" "${RUN_RC}" "rejects ProxyJump in password mode"
  assert_contains "${RUN_STDERR}" "does not allow ProxyJump" "stderr reports ProxyJump rejection"
  assert_file_not_exists "${STATE_DIR}/pass.args" "does not read password when ProxyJump is active"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked when ProxyJump is active"
}

test_security_runtime_dir_validation() {
  # Disk-backed XDG_RUNTIME_DIR under TEST_ROOT must use /dev/shm instead.
  setup_case "security_rt_disk"
  local disk_dir="${CASE_DIR}/disk_runtime"
  mkdir -p "${disk_dir}"
  chmod 700 "${disk_dir}"

  CUSTOM_RUNTIME_DIR="${disk_dir}" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "uses /dev/shm on disk-backed XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of disk"
  assert_dir_empty "${disk_dir}" "disk dir never used"

  # Symlink XDG_RUNTIME_DIR (with trailing slash) must be rejected.
  setup_case "security_rt_symlink"
  local link_dir="${RUNTIME_ROOT}/symlink_rt"
  ln -s "${RUNTIME_DIR}" "${link_dir}"

  CUSTOM_RUNTIME_DIR="${link_dir}/" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  rm -f "${link_dir}"
  assert_eq "0" "${RUN_RC}" "uses /dev/shm on symlink XDG_RUNTIME_DIR with trailing slash"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of symlink"
  assert_dir_empty "${RUNTIME_DIR}" "symlink target never used"

  # Symlinked ancestor component must be rejected.
  setup_case "security_rt_symlink_ancestor"
  local ancestor_link="${RUNTIME_ROOT}/ancestor_link"
  ln -s "${RUNTIME_DIR}" "${ancestor_link}"
  mkdir -p "${RUNTIME_DIR}/nested"
  chmod 700 "${RUNTIME_DIR}/nested"

  CUSTOM_RUNTIME_DIR="${ancestor_link}/nested" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  rm -f "${ancestor_link}"
  assert_eq "0" "${RUN_RC}" "uses /dev/shm on symlinked ancestor XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of symlinked ancestor"
  assert_dir_empty "${RUNTIME_DIR}/nested" "nested dir under symlink ancestor never used"

  # Directory owned by another user (root-owned /dev/shm passed as XDG_RUNTIME_DIR) fails owner check.
  setup_case "security_rt_other_owner"
  CUSTOM_RUNTIME_DIR="/run" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "rejects non-user-owned XDG_RUNTIME_DIR and uses /dev/shm"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of root-owned dir"

  # Relative XDG_RUNTIME_DIR must be rejected.
  setup_case "security_rt_relative"
  CUSTOM_RUNTIME_DIR="relative/runtime" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_SSH_MODE="record_dir" \
    run_bw_ssh alice@web01

  assert_eq "0" "${RUN_RC}" "uses /dev/shm on relative XDG_RUNTIME_DIR"
  assert_contains "$(cat "${STATE_DIR}/askpass.dir")" "/dev/shm/bw_ssh." "used /dev/shm instead of relative path"

  # Fail closed when /dev/shm is not root-owned and XDG_RUNTIME_DIR is invalid.
  setup_case "security_rt_shm_non_root"
  cat > "${MOCK_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-f"* ]]; then
  printf 'tmpfs\n'
else
  printf '1000\n'
fi
EOF
  chmod +x "${MOCK_BIN}/stat"

  CUSTOM_RUNTIME_DIR="${RUNTIME_ROOT}/missing-dir" \
    MOCK_PRIVKEY_RC=2 \
    run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "fails closed when /dev/shm is not owned by root"
  assert_contains "${RUN_STDERR}" "No writable RAM-backed runtime directory" "reports missing RAM-backed dir"

  # Fail closed when neither XDG_RUNTIME_DIR nor /dev/shm is tmpfs or ramfs.
  setup_case "security_rt_no_tmpfs"
  cat > "${MOCK_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-f"* ]]; then
  printf 'ext4\n'
else
  printf '0\n'
fi
EOF
  chmod +x "${MOCK_BIN}/stat"

  MOCK_PRIVKEY_RC=2 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "fails closed when no tmpfs runtime dir exists"
  assert_contains "${RUN_STDERR}" "No writable RAM-backed runtime directory" "reports missing RAM-backed dir"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked when no tmpfs exists"
}

test_security_invalid_ids_rejected() {
  setup_case "security_bad_item_uuid"
  MOCK_ITEM_ID="item-123" run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "rejects non-UUID itemID"
  assert_contains "${RUN_STDERR}" "invalid UUID" "stderr reports invalid item UUID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on bad itemID"

  setup_case "security_bad_privkey_id"
  MOCK_PRIVKEY_ID="../evil" run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "rejects invalid privkeyID"
  assert_contains "${RUN_STDERR}" "invalid attachment ID" "stderr reports invalid attachment ID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on bad privkeyID"
}

# --- Boundary and error paths ---

test_error_zero_args() {
  setup_case "error_zero_args"
  run_bw_ssh

  assert_eq "1" "${RUN_RC}" "exit code 1 on zero args"
  assert_eq "" "${RUN_STDOUT}" "empty stdout"
  assert_contains "${RUN_STDERR}" "Usage: bw.ssh [ssh-options] <destination> [command]" "usage on stderr"
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

test_error_ssh_g_missing_user_or_hostname() {
  setup_case "error_ssh_g_no_user"
  MOCK_SSH_G_OUT="hostname web01" run_bw_ssh web01
  assert_ne "0" "${RUN_RC}" "non-zero exit when user is empty"
  assert_contains "${RUN_STDERR}" "did not return user or hostname" "stderr reports missing user"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"

  setup_case "error_ssh_g_no_hostname"
  MOCK_SSH_G_OUT="user alice" run_bw_ssh alice
  assert_ne "0" "${RUN_RC}" "non-zero exit when hostname is empty"
  assert_contains "${RUN_STDERR}" "did not return user or hostname" "stderr reports missing hostname"
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
    assert_file_not_exists "${STATE_DIR}/pass.args" "does not use password auth on exit ${rc}"
    assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on exit ${rc}"
  done

  setup_case "error_privkey_empty"
  MOCK_PRIVKEY_EMPTY=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 on empty privKeyID"
  assert_file_not_exists "${STATE_DIR}/pass.args" "does not use password auth on empty privKeyID"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked on empty privKeyID"
}

test_error_bw_get_attachment_fails_or_empty() {
  setup_case "error_bw_attach_fail"
  MOCK_BW_ATTACH_RC=1 MOCK_SSH_ADD_RC=0 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "detects bw get attachment failure"
  assert_contains "${RUN_STDERR}" "Cannot read private key attachment" "stderr reports attachment read failure"
  assert_file_not_exists "${STATE_DIR}/ssh_add.args" "ssh-add not invoked on attachment failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
  assert_eq "42424" "$(cat "${STATE_DIR}/agent.killed_pid")" "kills ephemeral ssh-agent on attachment failure"

  setup_case "error_bw_attach_empty"
  MOCK_BW_ATTACH_EMPTY=1 MOCK_SSH_ADD_RC=0 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "rejects empty private key attachment"
  assert_contains "${RUN_STDERR}" "Private key attachment is empty" "stderr reports empty key"
  assert_file_not_exists "${STATE_DIR}/ssh_add.args" "ssh-add not invoked on empty key"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
  assert_eq "42424" "$(cat "${STATE_DIR}/agent.killed_pid")" "kills ephemeral ssh-agent on empty key"
}

test_error_ssh_add_fails() {
  setup_case "error_ssh_add_fails"
  MOCK_BW_ATTACH_RC=0 MOCK_SSH_ADD_RC=1 run_bw_ssh alice@web01

  assert_eq "1" "${RUN_RC}" "exits 1 when ssh-add fails"
  assert_contains "${RUN_STDERR}" "Cannot load private key" "stderr reports key load failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_password_invalid_or_missing() {
  setup_case "error_pass_fails_rc1"
  MOCK_PRIVKEY_RC=2 MOCK_PASS_RC=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 when bw.item.pass exits 1"
  assert_contains "${RUN_STDERR}" "Cannot read password" "stderr reports password read failure"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
  assert_dir_empty "${RUNTIME_DIR}" "no temp dir created"

  setup_case "error_pass_missing_rc2"
  MOCK_PRIVKEY_RC=2 MOCK_PASS_RC=2 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 when bw.item.pass exits 2"
  assert_contains "${RUN_STDERR}" "Password is missing" "stderr reports missing password"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"

  setup_case "error_pass_empty"
  MOCK_PRIVKEY_RC=2 MOCK_PASS_EMPTY=1 run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 on empty password"
  assert_contains "${RUN_STDERR}" "empty or contains a line break" "stderr reports empty password"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"

  setup_case "error_pass_multiline"
  MOCK_PRIVKEY_RC=2 MOCK_PASSWORD=$'line1\nline2' run_bw_ssh alice@web01
  assert_eq "1" "${RUN_RC}" "exits 1 on multiline password"
  assert_contains "${RUN_STDERR}" "empty or contains a line break" "stderr reports multiline password"
  assert_file_not_exists "${STATE_DIR}/ssh.argv0" "ssh not invoked"
}

test_error_ssh_fails_immediately_without_askpass() {
  setup_case "error_ssh_255_no_askpass"
  MOCK_PRIVKEY_RC=2 MOCK_SSH_MODE="record_dir" MOCK_SSH_RC=255 run_bw_ssh alice@web01

  assert_eq "255" "${RUN_RC}" "forwards ssh exit 255"
  assert_file_not_exists "$(cat "${STATE_DIR}/askpass.dir")" "temp dir deleted after immediate ssh failure"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean"
}

test_signal_sigterm_cleans_up_password_and_key_modes() {
  # Password mode: SIGTERM deletes tmp_dir.
  setup_case "signal_sigterm_password"
  local bg_pid=0
  local wait_i=0
  local tmp_dir=""
  local sig_rc=0

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
  kill -TERM -- -"${bg_pid}" 2>/dev/null || true
  wait "${bg_pid}" || sig_rc=$?

  assert_ne "0" "${sig_rc}" "non-zero exit after SIGTERM in password mode"
  assert_file_not_exists "${tmp_dir}" "temp dir deleted on SIGTERM"
  assert_dir_empty "${RUNTIME_DIR}" "runtime dir clean after SIGTERM"

  # Key-auth mode: SIGTERM stops the ephemeral ssh-agent.
  setup_case "signal_sigterm_key_auth"
  bg_pid=0
  wait_i=0
  sig_rc=0

  PATH="${MOCK_BIN}:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
    STATE_DIR="${STATE_DIR}" \
    MOCK_SSH_MODE="sleep_agent" \
    setsid "${BW_SSH}" alice@web01 >"${STATE_DIR}/stdout" 2>"${STATE_DIR}/stderr" &
  bg_pid=$!

  while [[ ! -s "${STATE_DIR}/ready.agent_pid" && "${wait_i}" -lt 50 ]]; do
    sleep 0.1
    wait_i=$((wait_i + 1))
  done

  if [[ ! -s "${STATE_DIR}/ready.agent_pid" ]]; then
    kill -KILL -- -"${bg_pid}" 2>/dev/null || true
    fail_msg "mock ssh did not start in key-auth mode."
    return 1
  fi

  kill -TERM -- -"${bg_pid}" 2>/dev/null || true
  wait "${bg_pid}" || sig_rc=$?

  assert_ne "0" "${sig_rc}" "non-zero exit after SIGTERM in key-auth mode"
  assert_eq "42424" "$(cat "${STATE_DIR}/agent.killed_pid")" "ephemeral ssh-agent killed on SIGTERM"
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
  assert_contains "${shm_dir}" "/dev/shm/bw_ssh." "used /dev/shm on missing dir"
  assert_file_not_exists "${shm_dir}" "deleted /dev/shm temp dir on exit"

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
  assert_contains "${shm_dir}" "/dev/shm/bw_ssh." "used /dev/shm on unwritable dir"
  assert_file_not_exists "${shm_dir}" "deleted /dev/shm temp dir on exit"
}

test_regression_askpass_key_in_host_or_user_allowed() {
  local secret="keystone-user-secret"

  setup_case "regression_askpass_keystone_host"
  MOCK_SSH_G_OUT="$(printf 'user root\nhostname keystone.example.com\n')" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_prompt" \
    MOCK_ASKPASS_PROMPT="root@keystone.example.com's password: " \
    run_bw_ssh root@keystone.example.com

  assert_eq "0" "${RUN_RC}" "keystone host run exits 0"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.prompt_rc")" "keystone host password prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.prompt_out")" "keystone host receives secret"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.prompt_err")" "keystone host askpass produces empty stderr"
  assert_eq "no" "$(cat "${STATE_DIR}/pass_exists_after_prompt")" "keystone host prompt deletes pass_file"

  setup_case "regression_askpass_keyadmin_user"
  MOCK_SSH_G_OUT="$(printf 'user keyadmin\nhostname turnkey-01\n')" \
    MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_prompt" \
    MOCK_ASKPASS_PROMPT="keyadmin@turnkey-01's password: " \
    run_bw_ssh keyadmin@turnkey-01

  assert_eq "0" "${RUN_RC}" "keyadmin user run exits 0"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.prompt_rc")" "keyadmin user password prompt succeeds"
  assert_eq "${secret}" "$(cat "${STATE_DIR}/askpass.prompt_out")" "keyadmin user receives secret"
  assert_eq "" "$(cat "${STATE_DIR}/askpass.prompt_err")" "keyadmin user askpass produces empty stderr"
  assert_eq "no" "$(cat "${STATE_DIR}/pass_exists_after_prompt")" "keyadmin user prompt deletes pass_file"

  setup_case "regression_askpass_keystone_tty_hostkey"
  MOCK_PRIVKEY_RC=2 \
    MOCK_PASSWORD="${secret}" \
    MOCK_SSH_MODE="askpass_tty" \
    MOCK_ASKPASS_PROMPT="The authenticity of host 'keystone' can't be established." \
    run_bw_ssh root@keystone.example.com

  assert_eq "0" "${RUN_RC}" "keystone tty host-key harness exits 0"
  assert_eq "0" "$(cat "${STATE_DIR}/askpass.tty_rc")" "keystone host-key prompt uses tty branch"
  assert_eq "no" "$(cat "${STATE_DIR}/askpass.tty_out")" "keystone host-key prompt returns user reply"
}

test_regression_ssh_tag_option_p_with_info_flag() {
  setup_case "regression_tag_p_g"
  MOCK_SSH_STDOUT="tag-g-output" run_bw_ssh -P mytag -G host
  assert_eq "0" "${RUN_RC}" "-P mytag -G exits 0"
  assert_eq "tag-g-output" "${RUN_STDOUT}" "-P mytag -G passes straight to ssh"
  assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "-P mytag -G skips bw.sess"
  assert_file_not_exists "${STATE_DIR}/search.args" "-P mytag -G skips bw.item.search"

  local -a recorded_args=()
  mapfile -d '' -t recorded_args < "${STATE_DIR}/ssh.argv0"
  assert_eq "4" "${#recorded_args[@]}" "-P mytag -G forwards all 4 args"
  assert_eq "-P" "${recorded_args[0]}" "arg 0 is -P"
  assert_eq "mytag" "${recorded_args[1]}" "arg 1 is mytag"
  assert_eq "-G" "${recorded_args[2]}" "arg 2 is -G"
  assert_eq "host" "${recorded_args[3]}" "arg 3 is host"

  setup_case "regression_tag_p_attached_g"
  MOCK_SSH_STDOUT="tag-attached-g" run_bw_ssh -Pmytag -G host
  assert_eq "0" "${RUN_RC}" "-Pmytag -G exits 0"
  assert_eq "tag-attached-g" "${RUN_STDOUT}" "-Pmytag -G passes straight to ssh"
  assert_not_contains "$(cat "${STATE_DIR}/calls.log")" "bw.sess" "-Pmytag -G skips bw.sess"
}

run_test test_happy_privkey_auth
run_test test_happy_hex_attachment_id_accepted
run_test test_happy_info_flags_pass_through
run_test test_happy_password_fallback
run_test test_happy_password_fallback_forwards_exit_code
run_test test_happy_ssh_g_hostname_parsing
run_test test_integration_real_ssh_g_and_real_ssh_agent
run_test test_security_ephemeral_ssh_agent_isolated_and_killed
run_test test_security_askpass_single_use_and_prompt_filtered
run_test test_security_askpass_atomic_race_and_tty_prompt
run_test test_security_password_auth_flags_and_proxyjump_rejection
run_test test_security_runtime_dir_validation
run_test test_security_invalid_ids_rejected
run_test test_error_zero_args
run_test test_error_bw_sess_fails
run_test test_error_ssh_g_fails
run_test test_error_ssh_g_missing_user_or_hostname
run_test test_error_item_search_fails
run_test test_error_privkey_fails_closed
run_test test_error_bw_get_attachment_fails_or_empty
run_test test_error_ssh_add_fails
run_test test_error_password_invalid_or_missing
run_test test_error_ssh_fails_immediately_without_askpass
run_test test_signal_sigterm_cleans_up_password_and_key_modes
run_test test_runtime_dir_fallback_to_dev_shm
run_test test_regression_askpass_key_in_host_or_user_allowed
run_test test_regression_ssh_tag_option_p_with_info_flag

printf '\ntest_bw_ssh.sh summary: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  exit 1
fi
