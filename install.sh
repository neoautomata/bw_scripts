#!/usr/bin/env bash

set -euo pipefail

PREFIX=""
CHECK_ONLY=0

REQUIRED_TOOLS=(
  bash
  jq
  keyctl
  ssh
  ssh-add
  ssh-agent
  ssh-keygen
  perl
  awk
  stat
  date
  install
  mktemp
  bw.bin
)

SCRIPTS=(
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

usage() {
  cat << 'EOF'
Usage: install.sh [options]

Install all Bitwarden helper scripts into a target directory.

Options:
  --prefix <dir>, --prefix=<dir>  Install scripts into <dir>. Default: ~/.local/bin.
  --check-only                    Check required host tools without installing files.
  --help, -h                      Show this help text and exit.
EOF
}

strip_trailing_slashes() {
  local path="${1}"
  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done
  printf '%s' "${path}"
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --prefix)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "Error: --prefix requires a directory path." >&2
        exit 1
      fi
      PREFIX="${2}"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#*=}"
      if [[ -z "${PREFIX}" ]]; then
        echo "Error: --prefix requires a directory path." >&2
        exit 1
      fi
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option ${1}." >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "${PREFIX}" ]]; then
  PREFIX="$(strip_trailing_slashes "${PREFIX}")"
  if [[ "${PREFIX}" == -* ]]; then
    echo "Error: Target directory path must not start with '-'." >&2
    exit 1
  fi
fi

missing_tools=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    missing_tools+=("${tool}")
  fi
done

if [[ "${#missing_tools[@]}" -gt 0 ]]; then
  echo "Error: Missing required host tools: ${missing_tools[*]}" >&2
  exit 1
fi

date_epoch=""
if ! date_epoch="$(date --date="2020-01-01T00:00:00Z" +%s 2>/dev/null)" || [[ "${date_epoch}" != "1577836800" ]]; then
  echo "Error: date must support the GNU --date option." >&2
  exit 1
fi

script_dir="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

bw_bin_path="$(command -v bw.bin)"
if [[ "${bw_bin_path}" -ef "${script_dir}/bw" ]]; then
  echo "Error: bw.bin must not point to ${script_dir}/bw." >&2
  exit 1
fi

if [[ -n "${PREFIX}" ]]; then
  check_bw="${PREFIX%/}/bw"
  if [[ -e "${check_bw}" && "${bw_bin_path}" -ef "${check_bw}" ]]; then
    echo "Error: bw.bin must not point to ${check_bw}." >&2
    exit 1
  fi
fi

echo "All required host tools exist."

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  exit 0
fi

if [[ -z "${PREFIX}" ]]; then
  if [[ -z "${HOME:-}" ]]; then
    echo "Error: HOME is empty. Specify --prefix <dir>." >&2
    exit 1
  fi
  PREFIX="$(strip_trailing_slashes "${HOME}/.local/bin")"
  if [[ "${PREFIX}" == -* ]]; then
    echo "Error: Target directory path must not start with '-'." >&2
    exit 1
  fi
fi

dest_prefix="${PREFIX%/}"
if [[ -e "${dest_prefix}/bw" && "${bw_bin_path}" -ef "${dest_prefix}/bw" ]]; then
  echo "Error: bw.bin must not point to ${dest_prefix}/bw." >&2
  exit 1
fi

# Reject symlinks and non-directory files on PREFIX and every existing ancestor.
check_path="${PREFIX}"
while [[ -n "${check_path}" && "${check_path}" != "/" && "${check_path}" != "." ]]; do
  if [[ -L "${check_path}" ]]; then
    echo "Error: Target path ${check_path} must not be a symlink." >&2
    exit 1
  fi
  if [[ -e "${check_path}" && ! -d "${check_path}" ]]; then
    echo "Error: Target path ${check_path} exists and is not a directory." >&2
    exit 1
  fi
  parent_path="$(dirname -- "${check_path}")"
  if [[ "${parent_path}" == "${check_path}" ]]; then
    break
  fi
  check_path="${parent_path}"
done

for script in "${SCRIPTS[@]}"; do
  src="${script_dir}/${script}"
  if [[ ! -f "${src}" || -L "${src}" ]]; then
    echo "Error: Source script ${src} must be a regular file." >&2
    exit 1
  fi
done

mkdir -p -- "${PREFIX}"

for script in "${SCRIPTS[@]}"; do
  dest="${dest_prefix}/${script}"
  if [[ -L "${dest}" ]]; then
    echo "Error: Destination ${dest} must not be a symlink." >&2
    exit 1
  fi
  if [[ -d "${dest}" ]]; then
    echo "Error: Destination ${dest} must not be a directory." >&2
    exit 1
  fi
  if [[ -e "${dest}" && ! -f "${dest}" ]]; then
    echo "Error: Destination ${dest} must be a regular file." >&2
    exit 1
  fi
done

stage_dir=""
# shellcheck disable=SC2317
cleanup_stage() {
  if [[ -n "${stage_dir}" && -d "${stage_dir}" ]]; then
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup_stage EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

stage_dir="$(mktemp -d "${dest_prefix}/.bw-install.XXXXXX")"

for script in "${SCRIPTS[@]}"; do
  install -m 0755 -- "${script_dir}/${script}" "${stage_dir}/${script}"
done

for script in "${SCRIPTS[@]}"; do
  mv -fT -- "${stage_dir}/${script}" "${dest_prefix}/${script}"
done

echo "Installed ${#SCRIPTS[@]} scripts into ${PREFIX}."
