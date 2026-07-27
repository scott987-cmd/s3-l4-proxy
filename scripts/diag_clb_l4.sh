#!/usr/bin/env bash
set -uo pipefail

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
CLB_IP="${LB_IP:-${CLB_IP:-${EIP:-}}}"
S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-tos-s3-${S3_REGION}.ivolces.com}}"
S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
S3_CLIENT_HOST="${S3_CLIENT_HOST:-${VHOST:-}}"

usage() {
  cat <<'USAGE'
Usage:
  LB_IP=<lb-vip-or-eip> S3_CLIENT_HOST=<signed-host> S3_BACKEND_HOST=<private-host> \
    bash scripts/diag_clb_l4.sh
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
    curl -sk --connect-timeout 3 --max-time 5 -o /dev/null \
      -w "curl_connect_code=%{exitcode} remote=%{remote_ip} connect=%{time_connect} total=%{time_total}\n" \
      "https://${host}:${port}/" || true
  elif command -v nc >/dev/null 2>&1; then
    nc -vz -G 3 "$host" "$port" 2>/dev/null || nc -vz -w 3 "$host" "$port" 2>&1 || true
  else
    bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>&1 \
      && echo "OPEN ${host}:${port}" || echo "CLOSED/FILTERED ${host}:${port}"
  fi
}

line "0. Target"
echo "LB_IP        = $CLB_IP"
echo "CLIENT_HOST  = $S3_CLIENT_HOST"
echo "BACKEND      = ${S3_BACKEND_HOST}:${S3_BACKEND_PORT}"

line "1. TCP connect to load balancer:443"
tcp_probe "$CLB_IP" 443

line "2. TLS handshake through the load balancer with S3 client host/SNI"
curl -sv --connect-timeout 10 -o /dev/null \
  --resolve "${S3_CLIENT_HOST}:443:${CLB_IP}" \
  "https://${S3_CLIENT_HOST}/" 2>&1 \
  | grep -Ei 'Trying|Connected|SSL connection|subject:|issuer:|HTTP/|reset|timed out|timeout|Could not|refused' \
  | head -40 || true

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
