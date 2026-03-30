#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-first-rpc}"
SERVICE_USER="${SERVICE_USER:-}"
SERVICE_GROUP="${SERVICE_GROUP:-}"
IMPLEMENTATION="${IMPLEMENTATION:-cpp}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-18777}"
ROOT_DIR="${ROOT_DIR:-$HOME}"
TOKEN="${TOKEN:-}"
BIN_PATH="${BIN_PATH:-}"
LOG_DIR="${LOG_DIR:-}"
PID_FILE="${PID_FILE:-}"
ENV_FILE="${ENV_FILE:-/etc/first-rpc/first-rpc.env}"
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
ENABLE_SERVICE="${ENABLE_SERVICE:-1}"
START_SERVICE="${START_SERVICE:-1}"
FORCE_OVERWRITE="${FORCE_OVERWRITE:-0}"
USER_EXPLICIT=0
GROUP_EXPLICIT=0

usage() {
  cat <<'EOF'
Usage: ./install_systemd_service.sh [options]

Options:
  --service-name <name>    default: first-rpc
  --user <user>            required when installing as root
  --group <group>          required when installing as root
  --impl <cpp|rust>        default: cpp
  --build-type <type>      default: Release
  --host <host>            default: 0.0.0.0
  --port <port>            default: 18777
  --root <path>            default: current user's home
  --token <token>          optional auth token written to the env file
  --bin <path>             optional explicit server binary path
  --log-dir <path>         optional override for run_server.sh LOG_DIR
  --pid-file <path>        optional override for run_server.sh PID_FILE
  --env-file <path>        default: /etc/first-rpc/first-rpc.env
  --unit-file <path>       default: /etc/systemd/system/<service-name>.service
  --skip-enable            do not enable the service
  --skip-start             do not start or restart the service
  --force                  overwrite existing env/unit files
  --help

Examples:
  sudo ./install_systemd_service.sh --root /home/dma --user dma --group dma
  sudo ./install_systemd_service.sh --impl rust --root /srv/first-rpc --skip-start
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --user)
      SERVICE_USER="$2"
      USER_EXPLICIT=1
      shift 2
      ;;
    --group)
      SERVICE_GROUP="$2"
      GROUP_EXPLICIT=1
      shift 2
      ;;
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
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --unit-file)
      UNIT_FILE="$2"
      shift 2
      ;;
    --skip-enable)
      ENABLE_SERVICE=0
      shift
      ;;
    --skip-start)
      START_SERVICE=0
      shift
      ;;
    --force)
      FORCE_OVERWRITE=1
      shift
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

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

assert_writable_target() {
  local path="$1"
  if [[ -e "$path" && "$FORCE_OVERWRITE" != "1" ]]; then
    echo "Refusing to overwrite existing file without --force: $path" >&2
    exit 1
  fi
}

require_cmd systemctl
require_cmd install

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="$SCRIPT_DIR/systemd/first-rpc.service.template"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Missing systemd template: $TEMPLATE_PATH" >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Configured root path does not exist: $ROOT_DIR" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "This installer writes to system directories and must run as root." >&2
  exit 1
fi

if [[ "$USER_EXPLICIT" != "1" || "$GROUP_EXPLICIT" != "1" ]]; then
  echo "Installing a system service as root requires explicit --user and --group." >&2
  echo "Example: sudo ./install_systemd_service.sh --user dma --group dma --root /home/dma" >&2
  exit 1
fi

case "$IMPLEMENTATION" in
  cpp|rust)
    ;;
  *)
    echo "Unsupported implementation: $IMPLEMENTATION" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$ENV_FILE")"
mkdir -p "$(dirname "$UNIT_FILE")"

assert_writable_target "$ENV_FILE"
assert_writable_target "$UNIT_FILE"

cat >"$ENV_FILE" <<EOF
IMPLEMENTATION=$(shell_quote "$IMPLEMENTATION")
BUILD_TYPE=$(shell_quote "$BUILD_TYPE")
HOST=$(shell_quote "$HOST")
PORT=$(shell_quote "$PORT")
ROOT_DIR=$(shell_quote "$ROOT_DIR")
TOKEN=$(shell_quote "$TOKEN")
BIN_PATH=$(shell_quote "$BIN_PATH")
LOG_DIR=$(shell_quote "$LOG_DIR")
PID_FILE=$(shell_quote "$PID_FILE")
EOF

tmp_unit="$(mktemp)"
trap 'rm -f "$tmp_unit"' EXIT

sed \
  -e "s|__FIRST_RPC_USER__|$SERVICE_USER|g" \
  -e "s|__FIRST_RPC_GROUP__|$SERVICE_GROUP|g" \
  -e "s|__FIRST_RPC_WORKDIR__|$SCRIPT_DIR|g" \
  -e "s|__FIRST_RPC_ENV_FILE__|$ENV_FILE|g" \
  "$TEMPLATE_PATH" >"$tmp_unit"

install -m 0644 "$tmp_unit" "$UNIT_FILE"

systemctl daemon-reload

if [[ "$ENABLE_SERVICE" == "1" ]]; then
  systemctl enable "$SERVICE_NAME"
fi

if [[ "$START_SERVICE" == "1" ]]; then
  systemctl restart "$SERVICE_NAME"
else
  echo "Service install completed without starting."
fi

echo "Installed service:"
echo "  service name: $SERVICE_NAME"
echo "  unit file:    $UNIT_FILE"
echo "  env file:     $ENV_FILE"
echo "  repo root:    $SCRIPT_DIR"
echo "  implementation: $IMPLEMENTATION"
echo "  root dir:     $ROOT_DIR"
echo
echo "Useful commands:"
echo "  systemctl status $SERVICE_NAME"
echo "  systemctl restart $SERVICE_NAME"
echo "  journalctl -u $SERVICE_NAME -f"
