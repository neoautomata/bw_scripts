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
  ssh-keygen
  perl
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
  --prefix <dir>   Install scripts into <dir>. Default: ~/.local/bin
  --check-only     Check required host tools without installing files.
  --help           Show this help text and exit.
EOF
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

if [[ -n "${PREFIX}" && "${PREFIX}" == -* ]]; then
  echo "Error: Target directory path must not start with '-'." >&2
  exit 1
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

echo "All required host tools exist."

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  exit 0
fi

if [[ -z "${PREFIX}" ]]; then
  if [[ -z "${HOME:-}" ]]; then
    echo "Error: HOME is empty. Specify --prefix <dir>." >&2
    exit 1
  fi
  PREFIX="${HOME}/.local/bin"
  if [[ "${PREFIX}" == -* ]]; then
    echo "Error: Target directory path must not start with '-'." >&2
    exit 1
  fi
fi

if [[ -L "${PREFIX}" ]]; then
  echo "Error: Target directory ${PREFIX} must not be a symlink." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for script in "${SCRIPTS[@]}"; do
  src="${script_dir}/${script}"
  if [[ ! -f "${src}" || -L "${src}" ]]; then
    echo "Error: Source script ${src} must be a regular file." >&2
    exit 1
  fi
done

mkdir -p -- "${PREFIX}"

stage_dir=""
cleanup_stage() {
  if [[ -n "${stage_dir}" && -d "${stage_dir}" ]]; then
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup_stage EXIT INT TERM HUP

stage_dir="$(mktemp -d "${PREFIX}/.bw-install.XXXXXX")"

for script in "${SCRIPTS[@]}"; do
  install -m 0755 -- "${script_dir}/${script}" "${stage_dir}/${script}"
done

for script in "${SCRIPTS[@]}"; do
  mv -f -- "${stage_dir}/${script}" "${PREFIX}/${script}"
done

echo "Installed ${#SCRIPTS[@]} scripts into ${PREFIX}."
