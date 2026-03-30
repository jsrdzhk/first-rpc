#!/usr/bin/env bash

set -euo pipefail

BUILD_TYPE="${BUILD_TYPE:-Release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-18778}"
TOKEN="${TOKEN:-smoke-token-rust}"

usage() {
  cat <<'EOF'
Usage: ./rust/smoke_test_rust.sh [options]

Options:
  --build-type <Debug|Release>
  --host <host>
  --port <port>
  --token <token>
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-type)
      BUILD_TYPE="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
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

resolve_binary_path() {
  local name="$1"
  local repo_root="$2"
  local profile_dir="release"
  if [[ "$BUILD_TYPE" == "Debug" ]]; then
    profile_dir="debug"
  fi

  local candidate="$repo_root/target/$profile_dir/$name"
  if [[ -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  echo "Unable to find binary $name for build type $BUILD_TYPE. Run ./rust/rust_build.sh first." >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local expected="$2"
  local label="$3"

  if [[ "$text" != *"$expected"* ]]; then
    echo "$label did not contain expected text: $expected" >&2
    echo "Actual output:" >&2
    echo "$text" >&2
    exit 1
  fi
}

RUST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PATH="$(resolve_binary_path first_rpc_server_rust "$RUST_ROOT")"
CLIENT_PATH="$(resolve_binary_path first_rpc_client_rust "$RUST_ROOT")"

SMOKE_ROOT="$RUST_ROOT/build/smoke-test-rust"
SERVER_LOG="$SMOKE_ROOT/server.log"
SAMPLE_FILE="$SMOKE_ROOT/sample.log"

mkdir -p "$SMOKE_ROOT"
cat >"$SAMPLE_FILE" <<'EOF'
alpha line
beta line
ERROR target line
omega line
EOF

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$SERVER_PATH" --host "$HOST" --port "$PORT" --root "$SMOKE_ROOT" --token "$TOKEN" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 2

COMMON_ARGS=(--host "$HOST" --port "$PORT" --token "$TOKEN")

health="$("$CLIENT_PATH" "${COMMON_ARGS[@]}" health_check)"
assert_contains "$health" "ok: true" "health_check"
assert_contains "$health" "summary: server is healthy" "health_check"

list_dir="$("$CLIENT_PATH" "${COMMON_ARGS[@]}" list_dir --path .)"
assert_contains "$list_dir" "sample.log" "list_dir"

read_file="$("$CLIENT_PATH" "${COMMON_ARGS[@]}" read_file --path sample.log)"
assert_contains "$read_file" "ERROR target line" "read_file"

tail_file="$("$CLIENT_PATH" "${COMMON_ARGS[@]}" tail_file --path sample.log --lines 2)"
assert_contains "$tail_file" "ERROR target line" "tail_file"
assert_contains "$tail_file" "omega line" "tail_file"

grep_file="$("$CLIENT_PATH" "${COMMON_ARGS[@]}" grep_file --path sample.log --needle ERROR)"
assert_contains "$grep_file" "ERROR target line" "grep_file"

echo "Rust smoke test passed."
