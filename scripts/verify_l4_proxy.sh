#!/usr/bin/env bash
set -uo pipefail

S3_BACKEND_HOST=""
S3_BACKEND_PORT="443"
S3_CLIENT_HOST=""
LISTEN_PORT="443"
CONF_PATH="/etc/nginx/stream.d/s3-proxy.conf"
NGINX_MAIN="/etc/nginx/nginx.conf"
WARN_EXTRA_PORTS=1
CONF=""

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/verify_l4_proxy.sh [-c config.env] [-e backend-host] [-p listen-port]

Exit codes:
  0 all pass
  1 warnings present
  2 failures present
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

CLI_BACKEND_HOST=""
CLI_LISTEN_PORT=""

while getopts "c:e:p:h" opt; do
  case "$opt" in
    c) CONF="$OPTARG" ;;
    e) CLI_BACKEND_HOST="$OPTARG"; S3_BACKEND_HOST="$OPTARG" ;;
    p) CLI_LISTEN_PORT="$OPTARG"; LISTEN_PORT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -n "$CONF" ] && [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF"
  S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-}}"
  S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
  S3_CLIENT_HOST="${S3_CLIENT_HOST:-}"
  ENABLE_PROXY_PROTOCOL="${ENABLE_PROXY_PROTOCOL:-0}"
  INSTALL_DNS_RELOAD_TIMER="${INSTALL_DNS_RELOAD_TIMER:-1}"
  LISTEN_PORT="${LISTEN_PORT:-443}"
  CONF_PATH="${CONF_PATH:-/etc/nginx/stream.d/s3-proxy.conf}"
  NGINX_MAIN="${NGINX_MAIN:-/etc/nginx/nginx.conf}"
  # Explicit command-line flags win over values from the config file.
  [ -n "$CLI_BACKEND_HOST" ] && S3_BACKEND_HOST="$CLI_BACKEND_HOST"
  [ -n "$CLI_LISTEN_PORT" ] && LISTEN_PORT="$CLI_LISTEN_PORT"
fi

PASS=0
WARN=0
FAIL=0

pass() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\n%s\n' "$*"; }

has_stream_module() {
  nginx -V 2>&1 | grep -q -- '--with-stream ' && return 0
  grep -Rqs 'ngx_stream_module.so' /usr/share/nginx/modules /etc/nginx/modules-enabled /etc/nginx/modules.d 2>/dev/null && return 0
  find /usr/lib64/nginx/modules /usr/lib/nginx/modules /etc/nginx/modules \
    -name 'ngx_stream_module.so' 2>/dev/null | grep -q .
}

port_listen() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q "[.:]${LISTEN_PORT} "
  else
    return 1
  fi
}

tcp_connect() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -G 3 "$host" "$port" >/dev/null 2>&1 || nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  elif command -v curl >/dev/null 2>&1; then
    curl -sk --connect-timeout 3 --max-time 5 -o /dev/null "https://${host}:${port}/" >/dev/null 2>&1
  else
    bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

printf '===================================================================\n'
printf ' S3 L4 proxy verification  backend=%s:%s listen=%s\n' "$S3_BACKEND_HOST" "$S3_BACKEND_PORT" "$LISTEN_PORT"
printf '===================================================================\n'

section "1. Service"
if command -v nginx >/dev/null 2>&1; then
  pass "nginx binary exists"
else
  fail "nginx binary not found"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet nginx 2>/dev/null && pass "nginx service active" || fail "nginx service not active"
  systemctl is-enabled --quiet nginx 2>/dev/null && pass "nginx service enabled" || warn "nginx service not enabled"
else
  pgrep -x nginx >/dev/null 2>&1 && pass "nginx process exists" || fail "nginx process not found"
fi
port_listen && pass "listening on :${LISTEN_PORT}" || fail "not listening on :${LISTEN_PORT}"

section "2. nginx config"
if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
  pass "nginx -t passes"
else
  fail "nginx -t fails"
fi
if command -v nginx >/dev/null 2>&1 && has_stream_module; then
  pass "stream module available"
else
  fail "stream module missing"
fi
if [ -f "$CONF_PATH" ]; then
  pass "stream config exists: $CONF_PATH"
  grep -Eq 'proxy_pass[[:space:]]+\$' "$CONF_PATH" && fail "variable proxy_pass found in $CONF_PATH" || pass "stream proxy_pass is non-variable"
  grep -Eq '^[[:space:]]*ssl(_|[[:space:]])|ssl_certificate' "$CONF_PATH" && fail "stream config appears to terminate TLS" || pass "stream config does not terminate TLS"
  if [ "$ENABLE_PROXY_PROTOCOL" = "1" ]; then
    grep -Eq 'listen[[:space:]].*proxy_protocol' "$CONF_PATH" && pass "PROXY protocol enabled in stream listener" || fail "PROXY protocol expected but not configured"
  else
    grep -Eq 'listen[[:space:]].*proxy_protocol' "$CONF_PATH" && fail "PROXY protocol configured but ENABLE_PROXY_PROTOCOL!=1" || pass "PROXY protocol disabled consistently"
  fi
else
  fail "stream config missing: $CONF_PATH"
fi

section "3. Upstream and passthrough"
if [ -z "$S3_BACKEND_HOST" ]; then
  fail "S3_BACKEND_HOST is not set (no vendor default)"
elif getent hosts "$S3_BACKEND_HOST" >/dev/null 2>&1; then
  pass "DNS resolves $S3_BACKEND_HOST"
else
  fail "DNS cannot resolve $S3_BACKEND_HOST"
fi
tcp_connect "$S3_BACKEND_HOST" "$S3_BACKEND_PORT" && pass "direct TCP to ${S3_BACKEND_HOST}:${S3_BACKEND_PORT} works" || fail "direct TCP to ${S3_BACKEND_HOST}:${S3_BACKEND_PORT} failed"
if command -v curl >/dev/null 2>&1; then
  probe_host="${S3_CLIENT_HOST:-$S3_BACKEND_HOST}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "${probe_host}:${LISTEN_PORT}:127.0.0.1" \
    "https://${probe_host}:${LISTEN_PORT}/" 2>/dev/null || echo 000)"
  case "$code" in
    200|301|302|307|400|401|403|404|405) pass "local passthrough TLS reached S3 backend: HTTP $code" ;;
    000) fail "local passthrough TLS failed" ;;
    *) warn "local passthrough returned HTTP $code" ;;
  esac
else
  warn "curl not found; skip local passthrough check"
fi

section "4. Security baseline"
if grep -rEq 'ssl_certificate|ssl_certificate_key' /etc/nginx/stream.d "$CONF_PATH" 2>/dev/null; then
  fail "TLS certificate directive found in stream proxy config"
else
  pass "no certificate/private key in stream proxy config"
fi
if command -v ss >/dev/null 2>&1; then
  extra="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' \
    | grep -vE "^(${LISTEN_PORT}|22)$" | sort -u | paste -sd, -)"
  if [ -z "$extra" ]; then
    pass "no extra listening TCP ports except ${LISTEN_PORT}/22"
  elif [ "$WARN_EXTRA_PORTS" = "1" ]; then
    warn "extra listening TCP ports: $extra"
  fi
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -S OUTPUT 2>/dev/null | grep -q 'DROP' && pass "OUTPUT chain has DROP policy/rule" || warn "egress is not locked down"
else
  warn "iptables not found; skip egress check"
fi
if pgrep -x nginx >/dev/null 2>&1; then
  nginx_pid="$(pgrep -xn nginx)"
  nofile="$(awk '/Max open files/{print $4}' "/proc/${nginx_pid}/limits" 2>/dev/null || true)"
  if [ -n "$nofile" ]; then
    [ "$nofile" -ge 65535 ] && pass "nginx nofile limit is $nofile" || warn "nginx nofile limit is $nofile"
  fi
fi

section "5. Operations baseline"
if [ -f /etc/logrotate.d/s3-l4-proxy ]; then
  pass "logrotate policy installed"
else
  warn "logrotate policy missing"
fi
if [ -f /etc/sysctl.d/99-s3-l4-proxy.conf ]; then
  pass "network sysctl baseline installed"
else
  warn "network sysctl baseline missing"
fi
if [ -f /var/log/nginx/s3-stream.log ]; then
  pass "stream access log exists"
else
  warn "stream access log not created yet"
fi
if [ "$INSTALL_DNS_RELOAD_TIMER" = "1" ]; then
  if systemctl is-enabled --quiet s3-l4-dns-reload.timer 2>/dev/null && \
     systemctl is-active --quiet s3-l4-dns-reload.timer 2>/dev/null; then
    pass "backend DNS reload timer active"
  else
    warn "backend DNS reload timer not active"
  fi
fi

printf '\n===================================================================\n'
printf ' Summary: PASS=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 2
elif [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
