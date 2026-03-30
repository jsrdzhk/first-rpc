#!/usr/bin/env bash

set -euo pipefail

IMPLEMENTATION="${IMPLEMENTATION:-all}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --impl <cpp|rust|all>     default: all
  --build-type <type>       default: Release
  --install-dir <path>      default: /usr/local/bin
  --help

Examples:
  sudo ./install.sh
  sudo ./install.sh --impl cpp
  sudo ./install.sh --impl rust --build-type Debug --install-dir /usr/local/bin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)
      IMPLEMENTATION="$2"
      shift 2
      ;;
    --build-type)
      BUILD_TYPE="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

resolve_cpp_binaries() {
  local repo_root="$1"
  local build_type="$2"
  local build_dir="cmake-build-release"

  case "$build_type" in
    Debug)
      build_dir="cmake-build-debug"
      ;;
    Release|RelWithDebInfo|MinSizeRel)
      ;;
    *)
      echo "Unsupported C++ build type: $build_type" >&2
      exit 1
      ;;
  esac

  local names=(first_rpc_server first_rpc_client)
  local resolved=()
  local candidate

  for name in "${names[@]}"; do
    for candidate in \
      "$repo_root/$build_dir/$build_type/$name" \
      "$repo_root/$build_dir/$name"; do
      if [[ -x "$candidate" ]]; then
        resolved+=("$candidate")
        break
      fi
    done

    if [[ "${#resolved[@]}" -eq 0 || "${resolved[-1]}" != */"$name" ]]; then
      echo "Unable to find $name for build type $build_type. Run ./build.sh first." >&2
      exit 1
    fi
  done

  printf '%s\n' "${resolved[@]}"
}

resolve_rust_binaries() {
  local repo_root="$1"
  local build_type="$2"
  local profile_dir="release"

  if [[ "$build_type" == "Debug" ]]; then
    profile_dir="debug"
  fi

  local names=(first_rpc_server_rust first_rpc_client_rust)
  local resolved=()
  local candidate

  for name in "${names[@]}"; do
    candidate="$repo_root/rust/target/$profile_dir/$name"
    if [[ ! -x "$candidate" ]]; then
      echo "Unable to find $name for build type $build_type. Run ./rust/build.sh first." >&2
      exit 1
    fi
    resolved+=("$candidate")
  done

  printf '%s\n' "${resolved[@]}"
}

require_cmd install

case "$IMPLEMENTATION" in
  cpp|rust|all)
    ;;
  *)
    echo "Unsupported implementation: $IMPLEMENTATION" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$EUID" -ne 0 ]]; then
  echo "This installer writes to $INSTALL_DIR and should usually run as root." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

resolved_files=()
if [[ "$IMPLEMENTATION" == "cpp" || "$IMPLEMENTATION" == "all" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && resolved_files+=("$file")
  done < <(resolve_cpp_binaries "$SCRIPT_DIR" "$BUILD_TYPE")
fi

if [[ "$IMPLEMENTATION" == "rust" || "$IMPLEMENTATION" == "all" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && resolved_files+=("$file")
  done < <(resolve_rust_binaries "$SCRIPT_DIR" "$BUILD_TYPE")
fi

for file in "${resolved_files[@]}"; do
  destination="$INSTALL_DIR/$(basename "$file")"
  install -m 0755 "$file" "$destination"
  echo "Installed $(basename "$file") -> $destination"
done

echo
echo "Available commands:"
for file in "${resolved_files[@]}"; do
  echo "  $(basename "$file")"
done
