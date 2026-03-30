#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-first-rpc}"
ENV_FILE="${ENV_FILE:-/etc/first-rpc/first-rpc.env}"
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
REMOVE_ENV_FILE="${REMOVE_ENV_FILE:-1}"
REMOVE_UNIT_FILE="${REMOVE_UNIT_FILE:-1}"
PURGE_ENV_DIR="${PURGE_ENV_DIR:-0}"

usage() {
  cat <<'EOF'
Usage: ./uninstall_systemd_service.sh [options]

Options:
  --service-name <name>    default: first-rpc
  --env-file <path>        default: /etc/first-rpc/first-rpc.env
  --unit-file <path>       default: /etc/systemd/system/<service-name>.service
  --keep-env               keep the environment file
  --keep-unit              keep the unit file
  --purge-env-dir          remove the env file parent directory if it becomes empty
  --help

Examples:
  sudo ./uninstall_systemd_service.sh
  sudo ./uninstall_systemd_service.sh --service-name first-rpc-test --keep-env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)
      SERVICE_NAME="$2"
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
    --keep-env)
      REMOVE_ENV_FILE=0
      shift
      ;;
    --keep-unit)
      REMOVE_UNIT_FILE=0
      shift
      ;;
    --purge-env-dir)
      PURGE_ENV_DIR=1
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

require_cmd systemctl

if [[ "$EUID" -ne 0 ]]; then
  echo "This uninstaller modifies systemd state and must run as root." >&2
  exit 1
fi

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

if [[ "$REMOVE_UNIT_FILE" == "1" && -f "$UNIT_FILE" ]]; then
  rm -f "$UNIT_FILE"
fi

if [[ "$REMOVE_ENV_FILE" == "1" && -f "$ENV_FILE" ]]; then
  rm -f "$ENV_FILE"
fi

if [[ "$PURGE_ENV_DIR" == "1" ]]; then
  env_dir="$(dirname "$ENV_FILE")"
  if [[ -d "$env_dir" ]] && [[ -z "$(ls -A "$env_dir")" ]]; then
    rmdir "$env_dir"
  fi
fi

systemctl daemon-reload

echo "Removed service configuration:"
echo "  service name: $SERVICE_NAME"
echo "  unit file removed: $([[ "$REMOVE_UNIT_FILE" == "1" ]] && [[ ! -f "$UNIT_FILE" ]] && echo yes || echo no)"
echo "  env file removed:  $([[ "$REMOVE_ENV_FILE" == "1" ]] && [[ ! -f "$ENV_FILE" ]] && echo yes || echo no)"
