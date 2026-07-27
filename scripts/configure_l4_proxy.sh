#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash scripts/configure_l4_proxy.sh [CONFIG=config.env] [KEY=VALUE ...]

Important options:
  S3_BACKEND_HOST=s3-backend.internal.example.com
  S3_BACKEND_PORT=443
  LISTEN_PORT=443
  MAIN_MODE=auto|replace
  DEDICATED_PROXY_HOST=1|0
  HARDEN=1|0
  EGRESS_LOCK=1|0
  EGRESS_UNLOCK=1|0

Legacy TOS_ENDPOINT is accepted as an alias for S3_BACKEND_HOST.
This script configures only protocol-transparent L4 nginx stream passthrough.
USAGE
}

log() { printf '[l4-config] %s\n' "$*"; }
die() { printf '[l4-config][ERR] %s\n' "$*" >&2; exit 1; }

load_config() {
  local config_file="${CONFIG:-}"
  local arg
  for arg in "$@"; do
    case "$arg" in
      CONFIG=*) config_file="${arg#*=}" ;;
    esac
  done
  if [ -n "$config_file" ]; then
    [ -f "$config_file" ] || die "config file not found: $config_file"
    # shellcheck disable=SC1090
    source "$config_file"
  fi
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      # $arg is a literal KEY=VALUE pair here, which export accepts directly.
      # shellcheck disable=SC2163
      *=*) export "$arg" ;;
      *) die "unknown argument: $arg" ;;
    esac
  done

  REGION="${S3_REGION:-${REGION:-cn-beijing}}"
  S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-tos-s3-${REGION}.ivolces.com}}"
  S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
  LISTEN_PORT="${LISTEN_PORT:-443}"
  NGINX_MAIN="${NGINX_MAIN:-/etc/nginx/nginx.conf}"
  NGINX_USER="${NGINX_USER:-}"
  STREAM_DIR="${STREAM_DIR:-/etc/nginx/stream.d}"
  CONF_PATH="${CONF_PATH:-${STREAM_DIR}/s3-proxy.conf}"
  LEGACY_CONF_PATH="${LEGACY_CONF_PATH:-${STREAM_DIR}/tos-proxy.conf}"
  MAIN_MODE="${MAIN_MODE:-replace}"
  HARDEN="${HARDEN:-1}"
  DEDICATED_PROXY_HOST="${DEDICATED_PROXY_HOST:-1}"
  EGRESS_LOCK="${EGRESS_LOCK:-0}"
  EGRESS_UNLOCK="${EGRESS_UNLOCK:-0}"
  SSH_PORT="${SSH_PORT:-22}"
  EXTRA_ALLOW="${EXTRA_ALLOW:-}"
  NOFILE="${NOFILE:-65535}"
  APPLY_SYSCTL="${APPLY_SYSCTL:-1}"
  ENABLE_PROXY_PROTOCOL="${ENABLE_PROXY_PROTOCOL:-0}"
  INSTALL_DNS_RELOAD_TIMER="${INSTALL_DNS_RELOAD_TIMER:-1}"
  DNS_RELOAD_INTERVAL="${DNS_RELOAD_INTERVAL:-5min}"
  BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/s3-l4-proxy}"
  FIREWALL_CHAIN="${FIREWALL_CHAIN:-S3_L4_EGRESS}"
  if [ -z "$NGINX_USER" ]; then
    if getent passwd nginx >/dev/null 2>&1; then
      NGINX_USER=nginx
    elif getent passwd www-data >/dev/null 2>&1; then
      NGINX_USER=www-data
    else
      die "cannot determine nginx worker user; set NGINX_USER"
    fi
  fi
}

require_root() {
  [ "$(id -u)" = "0" ] || die "run as root or with sudo"
}

validate_inputs() {
  [[ "$S3_BACKEND_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid S3_BACKEND_HOST: $S3_BACKEND_HOST"
  [[ "$S3_BACKEND_PORT" =~ ^[0-9]+$ ]] || die "invalid S3_BACKEND_PORT: $S3_BACKEND_PORT"
  [ "$S3_BACKEND_PORT" -ge 1 ] && [ "$S3_BACKEND_PORT" -le 65535 ] || die "S3_BACKEND_PORT out of range"
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || die "invalid LISTEN_PORT: $LISTEN_PORT"
  [ "$LISTEN_PORT" -ge 1 ] && [ "$LISTEN_PORT" -le 65535 ] || die "LISTEN_PORT out of range"
  case "$MAIN_MODE" in auto|replace) ;; *) die "MAIN_MODE must be auto or replace" ;; esac
  case "$DEDICATED_PROXY_HOST" in 0|1) ;; *) die "DEDICATED_PROXY_HOST must be 0 or 1" ;; esac
  case "$ENABLE_PROXY_PROTOCOL" in 0|1) ;; *) die "ENABLE_PROXY_PROTOCOL must be 0 or 1" ;; esac
  [[ "$DNS_RELOAD_INTERVAL" =~ ^[0-9]+(s|min|h|d|w|ms|us)?$ ]] || die "invalid DNS_RELOAD_INTERVAL"
}

check_upstream() {
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$S3_BACKEND_HOST" >/dev/null || die "cannot resolve $S3_BACKEND_HOST"
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$S3_BACKEND_HOST" >/dev/null || die "cannot resolve $S3_BACKEND_HOST"
  else
    log "no getent/nslookup found; skipping DNS precheck"
  fi

  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "$S3_BACKEND_HOST" "$S3_BACKEND_PORT" >/dev/null 2>&1; then
      connected=0
    else
      connected=1
    fi
  elif command -v curl >/dev/null 2>&1; then
    if curl -sk --connect-timeout 5 --max-time 8 -o /dev/null "https://${S3_BACKEND_HOST}:${S3_BACKEND_PORT}/" >/dev/null 2>&1; then
      connected=0
    else
      connected=1
    fi
  elif bash -c "</dev/tcp/${S3_BACKEND_HOST}/${S3_BACKEND_PORT}" 2>/dev/null; then
    connected=0
  else
    connected=1
  fi
  if [ "$connected" -eq 0 ]; then
    log "backend reachable: ${S3_BACKEND_HOST}:${S3_BACKEND_PORT}"
  else
    die "cannot connect to ${S3_BACKEND_HOST}:${S3_BACKEND_PORT} from this host"
  fi
}

ensure_stream_module() {
  nginx -V 2>&1 | grep -q -- '--with-stream ' && return 0

  local module
  module="$(find /usr/lib64/nginx/modules /usr/lib/nginx/modules /etc/nginx/modules -name 'ngx_stream_module.so' 2>/dev/null | head -1 || true)"
  if [ -n "$module" ]; then
    if grep -Rqs 'ngx_stream_module.so' /usr/share/nginx/modules /etc/nginx/modules-enabled /etc/nginx/modules.d 2>/dev/null; then
      return 0
    fi
    if ! grep -q 'ngx_stream_module.so' "$NGINX_MAIN" 2>/dev/null; then
      cp -a "$NGINX_MAIN" "${NGINX_MAIN}.bak.stream.$(date +%Y%m%d%H%M%S)"
      {
        printf 'load_module %s;\n' "$module"
        cat "$NGINX_MAIN"
      } > "${NGINX_MAIN}.tmp"
      mv "${NGINX_MAIN}.tmp" "$NGINX_MAIN"
      log "loaded dynamic stream module: $module"
    fi
    return 0
  fi

  die "nginx stream module is not available"
}

ensure_main_config() {
  mkdir -p "$STREAM_DIR"

  if [ "$MAIN_MODE" = "replace" ]; then
    cp -a "$NGINX_MAIN" "${NGINX_MAIN}.bak.replace.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    sed "s|__NGINX_USER__|${NGINX_USER}|g; s|/etc/nginx/stream.d|${STREAM_DIR}|g; s|worker_rlimit_nofile 65535;|worker_rlimit_nofile ${NOFILE};|g" \
      "$ROOT/templates/nginx-main.conf" > "$NGINX_MAIN"
    log "replaced nginx main config with L4 stream template"
    return
  fi

  if ! grep -q 'stream[[:space:]]*{' "$NGINX_MAIN" 2>/dev/null; then
    cp -a "$NGINX_MAIN" "${NGINX_MAIN}.bak.stream-include.$(date +%Y%m%d%H%M%S)"
    {
      cat "$NGINX_MAIN"
      printf '\nstream {\n'
      printf "    include %s/*.conf;\n" "$STREAM_DIR"
      printf '}\n'
    } > "${NGINX_MAIN}.tmp"
    mv "${NGINX_MAIN}.tmp" "$NGINX_MAIN"
    log "added stream include to nginx main config"
  elif ! grep -q "$STREAM_DIR" "$NGINX_MAIN" 2>/dev/null; then
    die "nginx main config already has stream block; set MAIN_MODE=replace on a dedicated proxy host or add include manually"
  fi
}

write_stream_config() {
  mkdir -p "$(dirname "$CONF_PATH")"
  if [ "$LEGACY_CONF_PATH" != "$CONF_PATH" ] && [ -f "$LEGACY_CONF_PATH" ]; then
    if grep -qE 'TOS L4 TCP passthrough|Scheme B|tos-s3-' "$LEGACY_CONF_PATH"; then
      mv "$LEGACY_CONF_PATH" "${LEGACY_CONF_PATH}.migrated.$(date +%Y%m%d%H%M%S)"
      log "migrated legacy stream config: $LEGACY_CONF_PATH"
    else
      die "legacy stream config exists and is not recognized as managed: $LEGACY_CONF_PATH"
    fi
  fi
  [ -f "$CONF_PATH" ] && cp -a "$CONF_PATH" "${CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)"

  if [ "$ENABLE_PROXY_PROTOCOL" = "1" ]; then
    listen_options=" proxy_protocol"
    client_addr_var='$proxy_protocol_addr'
  else
    listen_options=""
    client_addr_var='$remote_addr'
  fi
  sed "s|__S3_BACKEND_HOST__|${S3_BACKEND_HOST}|g; s|__S3_BACKEND_PORT__|${S3_BACKEND_PORT}|g; s|__LISTEN_PORT__|${LISTEN_PORT}|g; s|__LISTEN_OPTIONS__|${listen_options}|g; s|__CLIENT_ADDR_VAR__|${client_addr_var}|g" \
    "$ROOT/templates/s3-stream.conf" > "$CONF_PATH"

  if grep -qE 'proxy_pass[[:space:]]+\$' "$CONF_PATH"; then
    die "generated config contains variable proxy_pass"
  fi
  log "wrote stream config: $CONF_PATH"
}

disable_default_http() {
  [ "$DEDICATED_PROXY_HOST" = "1" ] || {
    log "shared-host mode: keep existing http{} configuration"
    return
  }
  if grep -qE '^http[[:space:]]*\{' "$NGINX_MAIN" 2>/dev/null; then
    log "http{} remains in nginx.conf; use MAIN_MODE=replace on a dedicated proxy host"
  fi
}

set_nofile_limits() {
  if [ -f "$NGINX_MAIN" ]; then
    if grep -qE '^[[:space:]]*worker_rlimit_nofile' "$NGINX_MAIN"; then
      sed -i.bak_nofile -E "s/^[[:space:]]*worker_rlimit_nofile.*/worker_rlimit_nofile ${NOFILE};/" "$NGINX_MAIN"
    else
      cp -a "$NGINX_MAIN" "${NGINX_MAIN}.bak_nofile.$(date +%Y%m%d%H%M%S)"
      {
        printf 'worker_rlimit_nofile %s;\n' "$NOFILE"
        cat "$NGINX_MAIN"
      } > "${NGINX_MAIN}.tmp"
      mv "${NGINX_MAIN}.tmp" "$NGINX_MAIN"
    fi
  fi

  mkdir -p /etc/systemd/system/nginx.service.d
  {
    echo "[Service]"
    echo "LimitNOFILE=${NOFILE}"
  } > /etc/systemd/system/nginx.service.d/limits.conf
  systemctl daemon-reload 2>/dev/null || true
  log "set nginx nofile limit to $NOFILE"
}

install_runtime_baseline() {
  cp -a "$ROOT/templates/logrotate.conf" /etc/logrotate.d/s3-l4-proxy
  log "installed logrotate policy"
  if [ "$APPLY_SYSCTL" = "1" ]; then
    cp -a "$ROOT/templates/sysctl.conf" /etc/sysctl.d/99-s3-l4-proxy.conf
    sysctl --system >/dev/null
    log "applied network sysctl baseline"
  fi
  if [ "$INSTALL_DNS_RELOAD_TIMER" = "1" ] && command -v systemctl >/dev/null 2>&1; then
    cp -a "$ROOT/templates/dns-reload.service" /etc/systemd/system/s3-l4-dns-reload.service
    sed "s|__DNS_RELOAD_INTERVAL__|${DNS_RELOAD_INTERVAL}|g" \
      "$ROOT/templates/dns-reload.timer" > /etc/systemd/system/s3-l4-dns-reload.timer
    systemctl daemon-reload
    systemctl enable --now s3-l4-dns-reload.timer >/dev/null
    log "installed backend DNS reload timer: $DNS_RELOAD_INTERVAL"
  fi
}

egress_unlock() {
  command -v iptables >/dev/null 2>&1 || { log "iptables not found; skip unlock"; return; }
  iptables -D OUTPUT -j "$FIREWALL_CHAIN" 2>/dev/null || true
  iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
  iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
  log "removed dedicated egress chain $FIREWALL_CHAIN"
}

egress_lock() {
  [ "$EGRESS_LOCK" = "1" ] || { log "skip egress lock; EGRESS_LOCK!=1"; return; }
  command -v iptables >/dev/null 2>&1 || { log "iptables not found; skip egress lock"; return; }

  local ips
  ips="$(getent ahostsv4 "$S3_BACKEND_HOST" 2>/dev/null | awk '{print $1}' | sort -u)"
  [ -n "$ips" ] || die "cannot resolve $S3_BACKEND_HOST for egress lock"

  iptables -N "$FIREWALL_CHAIN" 2>/dev/null || true
  iptables -F "$FIREWALL_CHAIN"
  iptables -A "$FIREWALL_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A "$FIREWALL_CHAIN" -o lo -j ACCEPT
  iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$SSH_PORT" -j ACCEPT
  iptables -A "$FIREWALL_CHAIN" -p udp --dport 53 -j ACCEPT
  iptables -A "$FIREWALL_CHAIN" -p tcp --dport 53 -j ACCEPT

  local extra
  IFS=',' read -r -a extras <<< "$EXTRA_ALLOW"
  for extra in "${extras[@]}"; do
    extra="$(printf '%s' "$extra" | tr -d ' ')"
    [ -z "$extra" ] && continue
    iptables -A "$FIREWALL_CHAIN" -d "$extra" -j ACCEPT
  done

  local ip
  for ip in $ips; do
    iptables -A "$FIREWALL_CHAIN" -p tcp -d "$ip" --dport "$S3_BACKEND_PORT" -j ACCEPT
  done
  iptables -A "$FIREWALL_CHAIN" -j REJECT
  iptables -C OUTPUT -j "$FIREWALL_CHAIN" 2>/dev/null || iptables -I OUTPUT 1 -j "$FIREWALL_CHAIN"
  log "enabled dedicated egress chain for ${S3_BACKEND_HOST}:${S3_BACKEND_PORT}"
}

run_hardening() {
  [ "$EGRESS_UNLOCK" = "1" ] && { egress_unlock; return; }
  [ "$HARDEN" = "1" ] || { log "skip hardening; HARDEN!=1"; return; }
  disable_default_http
  set_nofile_limits
  install_runtime_baseline
  egress_lock
}

test_and_reload() {
  if ! nginx -t; then
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
  else
    nginx -s reload
  fi
  log "nginx reloaded"
}

backup_state() {
  RUN_BACKUP="${BACKUP_ROOT}/$(date +%Y%m%d%H%M%S)-$$"
  mkdir -p "$RUN_BACKUP"
  [ -f "$NGINX_MAIN" ] && cp -a "$NGINX_MAIN" "$RUN_BACKUP/nginx.conf"
  [ -f "$CONF_PATH" ] && cp -a "$CONF_PATH" "$RUN_BACKUP/stream.conf"
  [ -f "$LEGACY_CONF_PATH" ] && cp -a "$LEGACY_CONF_PATH" "$RUN_BACKUP/legacy-stream.conf"
  [ -f /etc/systemd/system/nginx.service.d/limits.conf ] && \
    cp -a /etc/systemd/system/nginx.service.d/limits.conf "$RUN_BACKUP/limits.conf"
  [ -f /etc/logrotate.d/s3-l4-proxy ] && cp -a /etc/logrotate.d/s3-l4-proxy "$RUN_BACKUP/logrotate.conf"
  [ -f /etc/sysctl.d/99-s3-l4-proxy.conf ] && cp -a /etc/sysctl.d/99-s3-l4-proxy.conf "$RUN_BACKUP/sysctl.conf"
  [ -f /etc/systemd/system/s3-l4-dns-reload.service ] && \
    cp -a /etc/systemd/system/s3-l4-dns-reload.service "$RUN_BACKUP/dns-reload.service"
  [ -f /etc/systemd/system/s3-l4-dns-reload.timer ] && \
    cp -a /etc/systemd/system/s3-l4-dns-reload.timer "$RUN_BACKUP/dns-reload.timer"
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "$RUN_BACKUP/iptables.rules" 2>/dev/null || true
  fi
  log "backup created: $RUN_BACKUP"
}

rollback_state() {
  [ -n "${RUN_BACKUP:-}" ] || return
  log "rolling back configuration from $RUN_BACKUP"
  [ -f "$RUN_BACKUP/nginx.conf" ] && cp -a "$RUN_BACKUP/nginx.conf" "$NGINX_MAIN"
  if [ -f "$RUN_BACKUP/stream.conf" ]; then
    cp -a "$RUN_BACKUP/stream.conf" "$CONF_PATH"
  else
    rm -f "$CONF_PATH"
  fi
  if [ -f "$RUN_BACKUP/legacy-stream.conf" ]; then
    cp -a "$RUN_BACKUP/legacy-stream.conf" "$LEGACY_CONF_PATH"
  fi
  if [ -s "$RUN_BACKUP/iptables.rules" ] && command -v iptables-restore >/dev/null 2>&1; then
    iptables-restore < "$RUN_BACKUP/iptables.rules" 2>/dev/null || true
  fi
  if [ -f "$RUN_BACKUP/limits.conf" ]; then
    mkdir -p /etc/systemd/system/nginx.service.d
    cp -a "$RUN_BACKUP/limits.conf" /etc/systemd/system/nginx.service.d/limits.conf
  else
    rm -f /etc/systemd/system/nginx.service.d/limits.conf
  fi
  if [ -f "$RUN_BACKUP/logrotate.conf" ]; then
    cp -a "$RUN_BACKUP/logrotate.conf" /etc/logrotate.d/s3-l4-proxy
  else
    rm -f /etc/logrotate.d/s3-l4-proxy
  fi
  if [ -f "$RUN_BACKUP/sysctl.conf" ]; then
    cp -a "$RUN_BACKUP/sysctl.conf" /etc/sysctl.d/99-s3-l4-proxy.conf
  else
    rm -f /etc/sysctl.d/99-s3-l4-proxy.conf
  fi
  if [ -f "$RUN_BACKUP/dns-reload.service" ]; then
    cp -a "$RUN_BACKUP/dns-reload.service" /etc/systemd/system/s3-l4-dns-reload.service
  else
    rm -f /etc/systemd/system/s3-l4-dns-reload.service
  fi
  if [ -f "$RUN_BACKUP/dns-reload.timer" ]; then
    cp -a "$RUN_BACKUP/dns-reload.timer" /etc/systemd/system/s3-l4-dns-reload.timer
    systemctl enable --now s3-l4-dns-reload.timer >/dev/null 2>&1 || true
  else
    systemctl disable --now s3-l4-dns-reload.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/s3-l4-dns-reload.timer
  fi
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && {
    systemctl restart nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
  }
}

main() {
  load_config "$@"
  require_root
  validate_inputs
  command -v nginx >/dev/null 2>&1 || die "nginx not found; run install_l4_proxy.sh or install nginx first"
  check_upstream
  backup_state
  trap 'rollback_state' ERR
  ensure_stream_module
  ensure_main_config
  write_stream_config
  run_hardening
  test_and_reload
  trap - ERR
}

main "$@"
