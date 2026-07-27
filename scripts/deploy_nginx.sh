#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/deploy_nginx.sh [CONFIG=config.env] [KEY=VALUE ...]

Installs nginx and the stream module when needed. It does not write proxy
configuration; run configure_l4_proxy.sh after this script.

Options:
  INSTALL_NGINX=1|0
  WITH_STREAM=1|0
USAGE
}

log() { printf '[l4-deploy] %s\n' "$*"; }
die() { printf '[l4-deploy][ERR] %s\n' "$*" >&2; exit 1; }

load_config() {
  local config_file="${CONFIG:-}"
  local argument
  for argument in "$@"; do
    case "$argument" in
      CONFIG=*) config_file="${argument#*=}" ;;
    esac
  done
  if [ -n "$config_file" ]; then
    [ -f "$config_file" ] || die "config file not found: $config_file"
    # shellcheck disable=SC1090
    source "$config_file"
  fi
  for argument in "$@"; do
    case "$argument" in
      -h|--help) usage; exit 0 ;;
      *=*) export "$argument" ;;
      *) die "unknown argument: $argument" ;;
    esac
  done
  INSTALL_NGINX="${INSTALL_NGINX:-1}"
  WITH_STREAM="${WITH_STREAM:-1}"
}

require_root() {
  [ "$(id -u)" = "0" ] || die "run as root or with sudo"
}

package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  else
    die "unsupported package manager; expected apt, dnf, or yum"
  fi
}

install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log "nginx already installed: $(nginx -v 2>&1)"
  elif [ "$INSTALL_NGINX" = "0" ]; then
    die "nginx not installed and INSTALL_NGINX=0"
  else
    local manager
    manager="$(package_manager)"
    case "$manager" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y nginx
        ;;
      dnf)
        dnf install -y nginx
        ;;
      yum)
        yum install -y nginx
        ;;
    esac
    log "installed nginx: $(nginx -v 2>&1)"
  fi
}

install_stream_module() {
  nginx -V 2>&1 | grep -q -- '--with-stream ' && {
    log "stream module built in"
    return
  }

  local module
  module="$(find /usr/lib64/nginx/modules /usr/lib/nginx/modules /etc/nginx/modules \
    -name 'ngx_stream_module.so' 2>/dev/null | head -1 || true)"
  if [ -n "$module" ]; then
    log "stream dynamic module already present"
    return
  fi

  [ "$WITH_STREAM" = "1" ] || die "stream module missing and WITH_STREAM=0"

  local manager
  manager="$(package_manager)"
  case "$manager" in
    apt)
      apt-get install -y libnginx-mod-stream || true
      ;;
    dnf)
      dnf install -y nginx-mod-stream || true
      ;;
    yum)
      yum install -y nginx-mod-stream || true
      ;;
  esac

  module="$(find /usr/lib64/nginx/modules /usr/lib/nginx/modules /etc/nginx/modules \
    -name 'ngx_stream_module.so' 2>/dev/null | head -1 || true)"
  if nginx -V 2>&1 | grep -q -- '--with-stream ' || [ -n "$module" ]; then
    log "stream module is available"
  else
    die "stream module is still unavailable after package install"
  fi
}

start_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx 2>/dev/null || true
  fi
  log "deploy complete; next run: sudo bash scripts/configure_l4_proxy.sh CONFIG=config.env"
}

main() {
  load_config "$@"
  require_root
  install_nginx
  install_stream_module
  start_nginx
}

main "$@"
