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
GRPC_VERSION="${GRPC_VERSION:-}"
PARALLEL="${PARALLEL:-}"
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
  --parallel <jobs>
  --skip-clone
  --skip-build
  --help

Environment overrides:
  BUILD_TYPE
  HTTP_PROXY_VALUE
  GCC_C
  GCC_CXX
  GRPC_VERSION
  PARALLEL
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
    --parallel)
      PARALLEL="$2"
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

extract_major_version() {
  local compiler_bin="$1"
  local version_output
  version_output="$("$compiler_bin" -dumpfullversion -dumpversion 2>/dev/null || true)"
  version_output="${version_output%% *}"
  version_output="${version_output%%.*}"
  echo "$version_output"
}

validate_compiler_versions() {
  local gcc_major
  local gxx_major

  echo "Detected gcc: $("$GCC_C" --version | head -n 1)"
  echo "Detected g++: $("$GCC_CXX" --version | head -n 1)"

  gcc_major="$(extract_major_version "$GCC_C")"
  gxx_major="$(extract_major_version "$GCC_CXX")"

  if [[ -z "$gcc_major" || -z "$gxx_major" ]]; then
    echo "Unable to determine compiler major version. Please verify gcc/g++ are available in the current shell." >&2
    exit 1
  fi

  if [[ ! "$gcc_major" =~ ^[0-9]+$ || ! "$gxx_major" =~ ^[0-9]+$ ]]; then
    echo "Compiler version check failed: gcc=$gcc_major, g++=$gxx_major" >&2
    exit 1
  fi

  if [[ "$gcc_major" != "$gxx_major" ]]; then
    echo "gcc and g++ major versions do not match: gcc=$gcc_major, g++=$gxx_major" >&2
    echo "Please enter the intended toolchain first, for example: scl enable devtoolset-11 bash" >&2
    exit 1
  fi

  if (( gcc_major < 11 )); then
    echo "gcc/g++ major version must be at least 11. Current version: $gcc_major" >&2
    echo "Please enter the intended toolchain first, for example: scl enable devtoolset-11 bash" >&2
    exit 1
  fi
}

resolve_grpc_ref() {
  local repo_path="$1"
  local requested_ref="$2"

  if [[ -n "$requested_ref" ]]; then
    echo "$requested_ref"
    return 0
  fi

  local stable_tag
  stable_tag="$(git -C "$repo_path" tag --list 'v*' --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)"
  if [[ -z "$stable_tag" ]]; then
    echo "No stable non-pre gRPC tag was found in $repo_path" >&2
    exit 1
  fi

  echo "$stable_tag"
}

resolve_git_default_branch() {
  local repo_path="$1"
  local remote_head_ref

  remote_head_ref="$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$remote_head_ref" ]]; then
    echo "${remote_head_ref#refs/remotes/origin/}"
    return 0
  fi

  git -C "$repo_path" remote set-head origin --auto >/dev/null 2>&1 || true
  remote_head_ref="$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$remote_head_ref" ]]; then
    echo "${remote_head_ref#refs/remotes/origin/}"
    return 0
  fi

  for candidate in master main; do
    if [[ -n "$(git -C "$repo_path" ls-remote --heads origin "$candidate")" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "Unable to determine origin default branch for $repo_path" >&2
  exit 1
}

require_cmd git
require_cmd cmake
require_cmd "$GCC_C"
require_cmd "$GCC_CXX"
validate_compiler_versions

if [[ -z "$PARALLEL" ]]; then
  PARALLEL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
fi

if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]] || (( PARALLEL < 1 )); then
  echo "Parallel job count must be a positive integer. Current value: $PARALLEL" >&2
  exit 1
fi

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
    git clone --recurse-submodules https://github.com/grpc/grpc "$GRPC_SOURCE_DIR"
  fi

  step "Pull latest gRPC default branch"
  git -C "$GRPC_SOURCE_DIR" fetch --prune --tags --all
  DEFAULT_BRANCH="$(resolve_git_default_branch "$GRPC_SOURCE_DIR")"
  git -C "$GRPC_SOURCE_DIR" checkout -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
  git -C "$GRPC_SOURCE_DIR" pull --ff-only origin "$DEFAULT_BRANCH"

  step "Switch gRPC source to resolved ref"
  RESOLVED_GRPC_REF="$(resolve_grpc_ref "$GRPC_SOURCE_DIR" "$GRPC_VERSION")"
  if [[ -z "$RESOLVED_GRPC_REF" ]]; then
    echo "Resolved gRPC ref is empty for $GRPC_SOURCE_DIR" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$GRPC_SOURCE_DIR" ls-remote --heads origin "$RESOLVED_GRPC_REF")" ]]; then
    git -C "$GRPC_SOURCE_DIR" checkout -B "$RESOLVED_GRPC_REF" "origin/$RESOLVED_GRPC_REF"
    git -C "$GRPC_SOURCE_DIR" pull --ff-only origin "$RESOLVED_GRPC_REF"
  else
    git -C "$GRPC_SOURCE_DIR" checkout "$RESOLVED_GRPC_REF"
  fi
  echo "Resolved gRPC ref: $RESOLVED_GRPC_REF"

  step "Update gRPC submodules"
  git -C "$GRPC_SOURCE_DIR" submodule update --init --recursive
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
  cmake --build "$GRPC_BUILD_DIR" --parallel "$PARALLEL"
  cmake --install "$GRPC_BUILD_DIR"
  echo "gRPC installed to $GRPC_INSTALL_DIR"
else
  echo "gRPC configure completed. Build/install skipped."
fi
popd >/dev/null
