#!/usr/bin/env bash
set -euo pipefail

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
CLB_IP="${LB_IP:-${CLB_IP:-${EIP:-}}}"
SIZE_MB="${SIZE_MB:-100}"
OBJECT_PREFIX="${OBJECT_PREFIX:-l4-proxy-test}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-${TOS_AK:-${AK:-}}}"
S3_SECRET_KEY="${S3_SECRET_KEY:-${TOS_SK:-${SK:-}}}"
S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"
S3_CLIENT_HOST="${S3_CLIENT_HOST:-${VHOST:-}}"
S3_SERVICE="${S3_SERVICE:-s3}"
S3_SIGV4_PROVIDER="${S3_SIGV4_PROVIDER:-aws:amz}"
SIGV4="${SIGV4:-${S3_SIGV4_PROVIDER}:${S3_REGION}:${S3_SERVICE}}"
LISTEN_PORT="${LISTEN_PORT:-443}"

usage() {
  cat <<'USAGE'
Usage:
  S3_ACCESS_KEY=... S3_SECRET_KEY=... LB_IP=<lb-vip-or-eip> \\
  S3_CLIENT_HOST=<signed-host> S3_REGION=<region> \
    bash scripts/speed_test_l4.sh

This test preserves the standard HTTPS URL, TLS SNI, and signed host while
mapping only the TCP connection to LB_IP:LISTEN_PORT with curl --connect-to.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ -n "$S3_ACCESS_KEY" ] || { echo "[speed][ERR] set S3_ACCESS_KEY (or legacy TOS_AK/AK)"; exit 2; }
[ -n "$S3_SECRET_KEY" ] || { echo "[speed][ERR] set S3_SECRET_KEY (or legacy TOS_SK/SK)"; exit 2; }
[ -n "$CLB_IP" ] || { echo "[speed][ERR] set LB_IP (or legacy CLB_IP/EIP)"; exit 2; }
[ -n "$S3_CLIENT_HOST" ] || { echo "[speed][ERR] set S3_CLIENT_HOST or legacy VHOST"; exit 2; }
[[ "$SIZE_MB" =~ ^[0-9]+$ ]] || { echo "[speed][ERR] SIZE_MB must be numeric"; exit 2; }
[[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -ge 1 ] && [ "$LISTEN_PORT" -le 65535 ] || {
  echo "[speed][ERR] LISTEN_PORT must be between 1 and 65535"
  exit 2
}

command -v curl >/dev/null 2>&1 || { echo "[speed][ERR] curl not found"; exit 2; }

auth_args=(--aws-sigv4 "$SIGV4" --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}")
if [ -n "$S3_SESSION_TOKEN" ]; then
  auth_args+=(-H "x-amz-security-token: ${S3_SESSION_TOKEN}")
fi

if command -v nc >/dev/null 2>&1; then
  nc -z -G 3 "$CLB_IP" "$LISTEN_PORT" >/dev/null 2>&1 || nc -z -w 3 "$CLB_IP" "$LISTEN_PORT" >/dev/null 2>&1 || {
    echo "[speed][ERR] cannot connect to load balancer ${CLB_IP}:${LISTEN_PORT}"
    exit 2
  }
else
  curl -sS --noproxy '*' --connect-timeout 3 --max-time 5 -o /dev/null \
    --connect-to "${S3_CLIENT_HOST}:443:${CLB_IP}:${LISTEN_PORT}" \
    "https://${S3_CLIENT_HOST}/" >/dev/null 2>&1 || {
    echo "[speed][ERR] cannot complete TLS through ${CLB_IP}:${LISTEN_PORT}"
    exit 2
  }
fi

md5of() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

human() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f MB/s", bytes / 1048576 }'
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

upload_file="$tmpdir/upload.bin"
download_file="$tmpdir/download.bin"
output_file="$tmpdir/curl.out"
key="${OBJECT_PREFIX}-$(date +%s).bin"

echo "== Target =="
echo "  LB_IP  = $CLB_IP"
echo "  PORT   = $LISTEN_PORT"
echo "  HOST   = $S3_CLIENT_HOST"
echo "  KEY    = $key"

echo
echo "== Generate ${SIZE_MB}MB file =="
dd if=/dev/urandom of="$upload_file" bs=1048576 count="$SIZE_MB" 2>/dev/null
upload_md5="$(md5of "$upload_file")"
echo "  md5(upload)=$upload_md5"

echo
echo "== PUT via load balancer =="
put_result="$(curl -s --noproxy '*' -o "$output_file" -w '%{http_code} %{time_total} %{speed_upload}' \
  -X PUT \
  --connect-to "${S3_CLIENT_HOST}:443:${CLB_IP}:${LISTEN_PORT}" \
  "${auth_args[@]}" \
  --data-binary @"$upload_file" \
  "https://${S3_CLIENT_HOST}/${key}")"
put_code="$(printf '%s' "$put_result" | awk '{print $1}')"
put_time="$(printf '%s' "$put_result" | awk '{print $2}')"
put_speed="$(printf '%s' "$put_result" | awk '{print $3}')"
echo "  code=$put_code time=${put_time}s speed=$(human "$put_speed") (${put_speed} B/s)"
[ "$put_code" = "200" ] || { echo "  body:"; sed -n '1,20p' "$output_file"; exit 1; }

echo
echo "== GET via load balancer =="
get_result="$(curl -s --noproxy '*' -o "$download_file" -w '%{http_code} %{time_total} %{speed_download}' \
  --connect-to "${S3_CLIENT_HOST}:443:${CLB_IP}:${LISTEN_PORT}" \
  "${auth_args[@]}" \
  "https://${S3_CLIENT_HOST}/${key}")"
get_code="$(printf '%s' "$get_result" | awk '{print $1}')"
get_time="$(printf '%s' "$get_result" | awk '{print $2}')"
get_speed="$(printf '%s' "$get_result" | awk '{print $3}')"
echo "  code=$get_code time=${get_time}s speed=$(human "$get_speed") (${get_speed} B/s)"
[ "$get_code" = "200" ] || exit 1

download_md5="$(md5of "$download_file")"
if [ "$upload_md5" = "$download_md5" ]; then
  echo "  md5 OK ($upload_md5)"
else
  echo "  md5 mismatch upload=$upload_md5 download=$download_md5"
  exit 1
fi

echo
echo "== DELETE cleanup =="
delete_code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' \
  -X DELETE \
  --connect-to "${S3_CLIENT_HOST}:443:${CLB_IP}:${LISTEN_PORT}" \
  "${auth_args[@]}" \
  "https://${S3_CLIENT_HOST}/${key}")"
echo "  code=$delete_code"

echo
echo "== Summary =="
echo "  PUT ${SIZE_MB}MB: $(human "$put_speed")"
echo "  GET ${SIZE_MB}MB: $(human "$get_speed")"
