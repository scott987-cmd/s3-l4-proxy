#!/usr/bin/env bash
set -uo pipefail

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
CLB_IP="${LB_IP:-${CLB_IP:-${EIP:-}}}"
S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-}}"
S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
S3_CLIENT_HOST="${S3_CLIENT_HOST:-${VHOST:-}}"
LISTEN_PORT="${LISTEN_PORT:-443}"

usage() {
  cat <<'USAGE'
Usage:
  LB_IP=<lb-vip-or-eip> S3_CLIENT_HOST=<signed-host> S3_BACKEND_HOST=<private-host> \
  LISTEN_PORT=<frontend-port> bash scripts/diag_clb_l4.sh
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ -n "$CLB_IP" ] || { echo "[diag][ERR] set LB_IP (or legacy CLB_IP/EIP)"; exit 2; }
[ -n "$S3_CLIENT_HOST" ] || { echo "[diag][ERR] set S3_CLIENT_HOST or VHOST"; exit 2; }

line() { printf '\n----- %s -----\n' "$*"; }

tcp_probe() {
  local host="$1"
  local port="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -sk --noproxy '*' --connect-timeout 3 --max-time 5 -o /dev/null \
      -w "curl_connect_code=%{exitcode} remote=%{remote_ip} connect=%{time_connect} total=%{time_total}\n" \
      "https://${host}:${port}/"
  elif command -v nc >/dev/null 2>&1; then
    nc -vz -G 3 "$host" "$port" 2>/dev/null || nc -vz -w 3 "$host" "$port" 2>&1
  else
    bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>&1 \
      && echo "OPEN ${host}:${port}" || echo "CLOSED/FILTERED ${host}:${port}"
  fi
}

line "0. Target"
echo "LB_IP        = $CLB_IP"
echo "CLIENT_HOST  = $S3_CLIENT_HOST"
echo "BACKEND      = ${S3_BACKEND_HOST}:${S3_BACKEND_PORT}"

line "1. TCP connect to load balancer:${LISTEN_PORT}"
if tcp_probe "$CLB_IP" "$LISTEN_PORT"; then
  :
else
  echo "[diag][ERR] TCP connection failed"
  exit 1
fi

line "2. TLS handshake through the load balancer with S3 client host/SNI"
tls_output="$(mktemp)"
trap 'rm -f "$tls_output"' EXIT
if curl -sS -v --noproxy '*' --connect-timeout 10 --max-time 15 -o /dev/null \
  --connect-to "${S3_CLIENT_HOST}:443:${CLB_IP}:${LISTEN_PORT}" \
  "https://${S3_CLIENT_HOST}/" >"$tls_output" 2>&1; then
  tls_rc=0
else
  tls_rc=$?
fi
grep -Ei 'Trying|Connected|SSL connection|subject:|issuer:|HTTP/|reset|timed out|timeout|Could not|refused' \
  "$tls_output" | head -40 || true
if [ "$tls_rc" -ne 0 ]; then
  echo "[diag][ERR] TLS passthrough failed (curl exit $tls_rc)"
  exit 1
fi

line "3. DNS resolution from this client"
if command -v getent >/dev/null 2>&1; then
  getent hosts "$S3_BACKEND_HOST" || true
  getent hosts "$S3_CLIENT_HOST" || true
elif command -v nslookup >/dev/null 2>&1; then
  nslookup "$S3_BACKEND_HOST" 2>&1 | tail -8 || true
  nslookup "$S3_CLIENT_HOST" 2>&1 | tail -8 || true
else
  echo "no getent/nslookup"
fi

line "4. Direct TCP to S3 backend from this client"
tcp_probe "$S3_BACKEND_HOST" "$S3_BACKEND_PORT"

line "DONE"
