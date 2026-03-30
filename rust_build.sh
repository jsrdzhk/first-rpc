#!/usr/bin/env bash

set -euo pipefail

if [[ -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
  export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
elif [[ -d "$HOME/.linuxbrew/bin" ]]; then
  export PATH="$HOME/.linuxbrew/bin:$HOME/.linuxbrew/sbin:$PATH"
fi

BUILD_TYPE="${BUILD_TYPE:-Release}"
HTTP_PROXY_VALUE="${HTTP_PROXY_VALUE-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<'EOF'
Usage: ./rust_build.sh [options]

Options:
  --build-type <Debug|Release>
  --http-proxy <url>
  --skip-build
  --help

Environment overrides:
  BUILD_TYPE
  HTTP_PROXY_VALUE
  SKIP_BUILD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-type)
      BUILD_TYPE="$2"
      shift 2
      ;;
    --http-proxy)
      HTTP_PROXY_VALUE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
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

step() {
  echo "==> $1"
}

require_cmd cargo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_PATH="$SCRIPT_DIR/rust/Cargo.toml"

if [[ -n "$HTTP_PROXY_VALUE" ]]; then
  export HTTP_PROXY="$HTTP_PROXY_VALUE"
  export HTTPS_PROXY="$HTTP_PROXY_VALUE"
  echo "Using proxy: $HTTP_PROXY_VALUE"
fi

pushd "$SCRIPT_DIR" >/dev/null
if [[ "$SKIP_BUILD" != "1" ]]; then
  step "Build Rust binaries"
  if [[ "$BUILD_TYPE" == "Release" ]]; then
    cargo build --release --manifest-path "$MANIFEST_PATH"
  else
    cargo build --manifest-path "$MANIFEST_PATH"
  fi
fi

echo "Rust build completed."
popd >/dev/null
