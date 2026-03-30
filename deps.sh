#!/usr/bin/env bash

set -euo pipefail

if [[ -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
  export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
elif [[ -d "$HOME/.linuxbrew/bin" ]]; then
  export PATH="$HOME/.linuxbrew/bin:$HOME/.linuxbrew/sbin:$PATH"
fi

BUILD_TYPE="${BUILD_TYPE:-Release}"
HTTP_PROXY_VALUE="${HTTP_PROXY_VALUE-}"
GCC_C="${GCC_C:-gcc}"
GCC_CXX="${GCC_CXX:-g++}"
GRPC_VERSION="${GRPC_VERSION:-v1.78.1}"
SKIP_CLONE="${SKIP_CLONE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<'EOF'
Usage: ./deps.sh [options]

Options:
  --build-type <Debug|Release|RelWithDebInfo|MinSizeRel>
  --http-proxy <url>
  --gcc <gcc binary>
  --gxx <g++ binary>
  --grpc-version <tag>
  --skip-clone
  --skip-build
  --help

Environment overrides:
  BUILD_TYPE
  HTTP_PROXY_VALUE
  GCC_C
  GCC_CXX
  GRPC_VERSION
  SKIP_CLONE
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
    --gcc)
      GCC_C="$2"
      shift 2
      ;;
    --gxx)
      GCC_CXX="$2"
      shift 2
      ;;
    --grpc-version)
      GRPC_VERSION="$2"
      shift 2
      ;;
    --skip-clone)
      SKIP_CLONE=1
      shift
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

case "$BUILD_TYPE" in
  Debug)
    BUILD_DIR_NAME="cmake-build-debug"
    BUILD_TYPE_LOWER="debug"
    ;;
  Release|RelWithDebInfo|MinSizeRel)
    BUILD_DIR_NAME="cmake-build-release"
    BUILD_TYPE_LOWER="release"
    ;;
  *)
    echo "Unsupported build type: $BUILD_TYPE" >&2
    exit 1
    ;;
esac

PLATFORM_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

step() {
  echo "==> $1"
}

require_cmd git
require_cmd cmake
require_cmd "$GCC_C"
require_cmd "$GCC_CXX"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THIRD_PARTY_ROOT="$REPO_ROOT/third_party"
GRPC_SOURCE_DIR="$THIRD_PARTY_ROOT/grpc-src"
GRPC_BUILD_DIR="$THIRD_PARTY_ROOT/grpc-build/$PLATFORM_NAME-$BUILD_TYPE_LOWER"
GRPC_INSTALL_DIR="$THIRD_PARTY_ROOT/grpc-install/$PLATFORM_NAME-$BUILD_TYPE_LOWER"

if [[ -n "$HTTP_PROXY_VALUE" ]]; then
  export HTTP_PROXY="$HTTP_PROXY_VALUE"
  export HTTPS_PROXY="$HTTP_PROXY_VALUE"
  echo "Using proxy: $HTTP_PROXY_VALUE"
fi

export CC="$GCC_C"
export CXX="$GCC_CXX"

pushd "$REPO_ROOT" >/dev/null
mkdir -p "$THIRD_PARTY_ROOT" "$GRPC_BUILD_DIR" "$GRPC_INSTALL_DIR"

if [[ "$SKIP_CLONE" != "1" ]]; then
  if [[ ! -d "$GRPC_SOURCE_DIR/.git" ]]; then
    step "Clone gRPC source"
    git clone --recurse-submodules -b "$GRPC_VERSION" --depth 1 --shallow-submodules https://github.com/grpc/grpc "$GRPC_SOURCE_DIR"
  else
    step "Update gRPC submodules"
    git -C "$GRPC_SOURCE_DIR" submodule update --init --recursive
  fi
fi

step "Configure gRPC"
cmake -S "$GRPC_SOURCE_DIR" -B "$GRPC_BUILD_DIR" \
  -DgRPC_INSTALL=ON \
  -DgRPC_BUILD_TESTS=OFF \
  -DABSL_PROPAGATE_CXX_STD=ON \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_INSTALL_PREFIX="$GRPC_INSTALL_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  step "Build and install gRPC"
  cmake --build "$GRPC_BUILD_DIR" --parallel 4
  cmake --install "$GRPC_BUILD_DIR"
  echo "gRPC installed to $GRPC_INSTALL_DIR"
else
  echo "gRPC configure completed. Build/install skipped."
fi
popd >/dev/null
