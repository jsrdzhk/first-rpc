#!/usr/bin/env bash

set -euo pipefail

ACTION="start"
if [[ $# -gt 0 ]]; then
  case "$1" in
    start|stop|restart|status)
      ACTION="$1"
      shift
      ;;
  esac
fi

IMPLEMENTATION="${IMPLEMENTATION:-cpp}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-18777}"
ROOT_DIR="${ROOT_DIR:-.}"
TOKEN="${TOKEN:-}"
BIN_PATH="${BIN_PATH:-}"
LOG_DIR="${LOG_DIR:-}"
PID_FILE="${PID_FILE:-}"
FOREGROUND="${FOREGROUND:-0}"

usage() {
  cat <<'EOF'
Usage: ./run_server.sh <start|stop|restart|status> [options]

Options:
  --impl <cpp|rust>
  --build-type <Debug|Release|RelWithDebInfo|MinSizeRel>
  --host <host>
  --port <port>
  --root <path>
  --token <token>
  --bin <path>
  --log-dir <path>
  --pid-file <path>
  --foreground
  --help

Environment overrides:
  IMPLEMENTATION
  BUILD_TYPE
  HOST
  PORT
  ROOT_DIR
  TOKEN
  BIN_PATH
  LOG_DIR
  PID_FILE
  FOREGROUND

Examples:
  ./run_server.sh start --host 0.0.0.0 --port 18777 --root /data/logs --token demo-token
  ./run_server.sh restart --impl rust --root /var/log/app --log-dir /tmp/first-rpc
  ./run_server.sh start --bin ./first_rpc_server --root /var/log/app
  ./run_server.sh status
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

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
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --root)
      ROOT_DIR="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --bin)
      BIN_PATH="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --pid-file)
      PID_FILE="$2"
      shift 2
      ;;
    --foreground)
      FOREGROUND=1
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

case "$ACTION" in
  start|stop|restart|status)
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    usage
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$SCRIPT_DIR/server-runtime/$IMPLEMENTATION"
fi

if [[ -z "$PID_FILE" ]]; then
  PID_FILE="$LOG_DIR/first_rpc_server.pid"
fi

STDOUT_LOG="$LOG_DIR/server.stdout.log"
STDERR_LOG="$LOG_DIR/server.stderr.log"

resolve_binary_path() {
  if [[ -n "$BIN_PATH" ]]; then
    if [[ -x "$BIN_PATH" ]]; then
      echo "$BIN_PATH"
      return 0
    fi
    echo "Configured binary is not executable or does not exist: $BIN_PATH" >&2
    exit 1
  fi

  local profile_dir
  case "$BUILD_TYPE" in
    Debug)
      profile_dir="debug"
      ;;
    Release|RelWithDebInfo|MinSizeRel)
      profile_dir="release"
      ;;
    *)
      echo "Unsupported build type: $BUILD_TYPE" >&2
      exit 1
      ;;
  esac

  local candidate
  if [[ "$IMPLEMENTATION" == "cpp" ]]; then
    for candidate in \
      "./first_rpc_server" \
      "$(pwd)/first_rpc_server"; do
      if [[ -x "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done

    local build_dir
    if [[ "$profile_dir" == "debug" ]]; then
      build_dir="cmake-build-debug"
    else
      build_dir="cmake-build-release"
    fi

    for candidate in \
      "$SCRIPT_DIR/$build_dir/first_rpc_server" \
      "$SCRIPT_DIR/$build_dir/$BUILD_TYPE/first_rpc_server"; do
      if [[ -x "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
    echo "Unable to find C++ server binary for build type $BUILD_TYPE. Run ./build.sh first." >&2
    exit 1
  fi

  if [[ "$IMPLEMENTATION" == "rust" ]]; then
    for candidate in \
      "./first_rpc_server_rust" \
      "$(pwd)/first_rpc_server_rust"; do
      if [[ -x "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done

    candidate="$SCRIPT_DIR/rust/target/$profile_dir/first_rpc_server_rust"
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    echo "Unable to find Rust server binary for build type $BUILD_TYPE. Run ./rust/build.sh first." >&2
    exit 1
  fi

  echo "Unsupported implementation: $IMPLEMENTATION" >&2
  exit 1
}

is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  if [[ -z "$pid" ]]; then
    return 1
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  rm -f "$PID_FILE"
  return 1
}

print_status() {
  if is_running; then
    echo "first-rpc server is running: pid=$(cat "$PID_FILE") impl=$IMPLEMENTATION port=$PORT"
  else
    echo "first-rpc server is not running"
  fi
}

stop_server() {
  if ! is_running; then
    echo "first-rpc server is not running"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  echo "Stopping first-rpc server pid=$pid"
  kill "$pid" >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$PID_FILE"
      echo "Stopped."
      return 0
    fi
    sleep 1
  done

  echo "Process did not exit in time, sending SIGKILL" >&2
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
}

start_server() {
  if is_running; then
    echo "first-rpc server already running: pid=$(cat "$PID_FILE")" >&2
    return 1
  fi

  local server_bin
  server_bin="$(resolve_binary_path)"

  mkdir -p "$LOG_DIR"

  local root_path
  root_path="$(cd "$ROOT_DIR" 2>/dev/null && pwd || true)"
  if [[ -z "$root_path" ]]; then
    echo "Root path does not exist or is not accessible: $ROOT_DIR" >&2
    exit 1
  fi

  local args=(
    --host "$HOST"
    --port "$PORT"
    --root "$root_path"
  )
  if [[ -n "$TOKEN" ]]; then
    args+=(--token "$TOKEN")
  fi

  if [[ "$FOREGROUND" == "1" ]]; then
    echo "Starting first-rpc server in foreground: impl=$IMPLEMENTATION host=$HOST port=$PORT root=$root_path"
    exec "$server_bin" "${args[@]}"
  fi

  echo "Starting first-rpc server: impl=$IMPLEMENTATION host=$HOST port=$PORT root=$root_path"
  nohup "$server_bin" "${args[@]}" >"$STDOUT_LOG" 2>"$STDERR_LOG" < /dev/null &
  local pid=$!
  echo "$pid" >"$PID_FILE"
  sleep 2

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "Started. pid=$pid"
    echo "stdout: $STDOUT_LOG"
    echo "stderr: $STDERR_LOG"
    echo "pidfile: $PID_FILE"
    return 0
  fi

  echo "Server exited immediately. Check logs:" >&2
  echo "stdout: $STDOUT_LOG" >&2
  echo "stderr: $STDERR_LOG" >&2
  rm -f "$PID_FILE"
  return 1
}

case "$ACTION" in
  start)
    start_server
    ;;
  stop)
    stop_server
    ;;
  restart)
    stop_server
    start_server
    ;;
  status)
    print_status
    ;;
esac
