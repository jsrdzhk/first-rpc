#!/usr/bin/env bash

set -euo pipefail

if [[ -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
  export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
elif [[ -d "$HOME/.linuxbrew/bin" ]]; then
  export PATH="$HOME/.linuxbrew/bin:$HOME/.linuxbrew/sbin:$PATH"
fi

BUILD_TYPE="${BUILD_TYPE:-Release}"
GENERATOR="${GENERATOR:-}"
HTTP_PROXY_VALUE="${HTTP_PROXY_VALUE-}"
GCC_C="${GCC_C:-gcc}"
GCC_CXX="${GCC_CXX:-g++}"
RUN_TESTS="${RUN_TESTS:-0}"
SKIP_CONFIGURE="${SKIP_CONFIGURE:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

Options:
  --build-type <Debug|Release|RelWithDebInfo|MinSizeRel>
  --generator <Ninja|Unix Makefiles|...>
  --http-proxy <url>
  --gcc <gcc binary>
  --gxx <g++ binary>
  --run-tests
  --skip-configure
  --skip-build
  --help

Environment overrides:
  BUILD_TYPE
  GENERATOR
  HTTP_PROXY_VALUE
  GCC_C
  GCC_CXX
  RUN_TESTS
  SKIP_CONFIGURE
  SKIP_BUILD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-type)
      BUILD_TYPE="$2"
      shift 2
      ;;
    --generator)
      GENERATOR="$2"
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
    --run-tests)
      RUN_TESTS=1
      shift
      ;;
    --skip-configure)
      SKIP_CONFIGURE=1
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
    BUILD_DIR="cmake-build-debug"
    BUILD_TYPE_SUFFIX="debug"
    ;;
  Release|RelWithDebInfo|MinSizeRel)
    BUILD_DIR="cmake-build-release"
    BUILD_TYPE_SUFFIX="release"
    ;;
  *)
    echo "Unsupported build type: $BUILD_TYPE" >&2
    exit 1
    ;;
esac

if [[ -z "$GENERATOR" ]]; then
  if command -v ninja >/dev/null 2>&1; then
    GENERATOR="Ninja"
  else
    GENERATOR="Unix Makefiles"
  fi
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

step() {
  echo "==> $1"
}

require_cmd cmake
require_cmd ctest
require_cmd "$GCC_C"
require_cmd "$GCC_CXX"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
PLATFORM_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
GRPC_INSTALL_DIR="$SCRIPT_DIR/third_party/grpc-install/$PLATFORM_NAME-$BUILD_TYPE_SUFFIX"

mkdir -p "$BUILD_DIR"

if [[ -n "$HTTP_PROXY_VALUE" ]]; then
  export HTTP_PROXY="$HTTP_PROXY_VALUE"
  export HTTPS_PROXY="$HTTP_PROXY_VALUE"
  echo "Using proxy: $HTTP_PROXY_VALUE"
fi

export CC="$GCC_C"
export CXX="$GCC_CXX"

if [[ ! -d "$GRPC_INSTALL_DIR" ]]; then
  echo "Local gRPC install not found in $GRPC_INSTALL_DIR. Run ./deps.sh --build-type $BUILD_TYPE first." >&2
  exit 1
fi

if [[ "$SKIP_CONFIGURE" != "1" ]]; then
  step "Configure CMake"
  cmake -S . -B "$BUILD_DIR" \
    -G "$GENERATOR" \
    -DFIRST_RPC_GRPC_ROOT="$GRPC_INSTALL_DIR" \
    -DCMAKE_PREFIX_PATH="$GRPC_INSTALL_DIR" \
    -DCMAKE_PROGRAM_PATH="$GRPC_INSTALL_DIR/bin" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_C_COMPILER="$GCC_C" \
    -DCMAKE_CXX_COMPILER="$GCC_CXX"
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  step "Build project"
  cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
fi

if [[ "$RUN_TESTS" == "1" ]]; then
  step "Run C++ unit tests"
  ctest --test-dir "$BUILD_DIR" --output-on-failure -C "$BUILD_TYPE"
fi

echo "Build completed."
