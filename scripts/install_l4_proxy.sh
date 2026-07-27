#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/install_l4_proxy.sh [CONFIG=config.env] [KEY=VALUE ...]

Installs nginx/stream module and applies the L4 S3 stream proxy config.
USAGE
}

for argument in "$@"; do
  case "$argument" in
    -h|--help) usage; exit 0 ;;
  esac
done

CONFIG_ARGS=("$@")

bash "$ROOT/scripts/deploy_nginx.sh" "${CONFIG_ARGS[@]}"
bash "$ROOT/scripts/configure_l4_proxy.sh" "${CONFIG_ARGS[@]}"

config_file="${CONFIG:-}"
for argument in "$@"; do
  case "$argument" in
    CONFIG=*) config_file="${argument#*=}" ;;
  esac
done
if [ -n "$config_file" ] && [ -f "$config_file" ]; then
  # shellcheck disable=SC1090
  source "$config_file"
fi
if [ "${VERIFY_AFTER_INSTALL:-1}" = "1" ]; then
  verify_args=()
  [ -n "$config_file" ] && verify_args=(-c "$config_file")
  if bash "$ROOT/scripts/verify_l4_proxy.sh" "${verify_args[@]}"; then
    :
  else
    verify_rc=$?
    if [ "$verify_rc" -ge 2 ]; then
      exit "$verify_rc"
    fi
    echo "[install] verification completed with warnings"
  fi
fi
