#!/usr/bin/env bash
set -euo pipefail

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
LB_IP="${LB_IP:-${CLB_IP:-${EIP:-}}}"
LISTEN_PORT="${LISTEN_PORT:-443}"
S3_CLIENT_HOST="${S3_CLIENT_HOST:-${VHOST:-}}"
S3_BUCKET="${S3_BUCKET:-${TEST_BUCKET:-${S3_CLIENT_HOST%%.*}}}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-${TOS_AK:-${AK:-}}}"
S3_SECRET_KEY="${S3_SECRET_KEY:-${TOS_SK:-${SK:-}}}"
S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"
S3_SERVICE="${S3_SERVICE:-s3}"
S3_SIGV4_PROVIDER="${S3_SIGV4_PROVIDER:-aws:amz}"
SIGV4="${SIGV4:-${S3_SIGV4_PROVIDER}:${S3_REGION}:${S3_SERVICE}}"
OBJECT_PREFIX="${OBJECT_PREFIX:-l4-functional-test}"

usage() {
  cat <<'USAGE'
Usage:
  S3_ACCESS_KEY=... S3_SECRET_KEY=... LB_IP=<frontend-ip> \
  LISTEN_PORT=<frontend-port> S3_CLIENT_HOST=<signed-bucket-host> \
    bash scripts/functional_test_l4.sh

Runs small-object S3 checks without performance or concurrency load:
PUT, GET, checksum, HEAD, metadata, Range GET, zero-byte object,
ListObjects, CopyObject, and cleanup DELETEs.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

[ -n "$S3_ACCESS_KEY" ] || { echo "[functional][ERR] S3_ACCESS_KEY is required"; exit 2; }
[ -n "$S3_SECRET_KEY" ] || { echo "[functional][ERR] S3_SECRET_KEY is required"; exit 2; }
[ -n "$LB_IP" ] || { echo "[functional][ERR] LB_IP is required"; exit 2; }
[ -n "$S3_CLIENT_HOST" ] || { echo "[functional][ERR] S3_CLIENT_HOST is required"; exit 2; }
[ -n "$S3_BUCKET" ] || { echo "[functional][ERR] S3_BUCKET is required"; exit 2; }
[[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -ge 1 ] && [ "$LISTEN_PORT" -le 65535 ] || {
  echo "[functional][ERR] LISTEN_PORT must be between 1 and 65535"
  exit 2
}
command -v curl >/dev/null 2>&1 || { echo "[functional][ERR] curl not found"; exit 2; }

auth_args=(--aws-sigv4 "$SIGV4" --user "${S3_ACCESS_KEY}:${S3_SECRET_KEY}")
if [ -n "$S3_SESSION_TOKEN" ]; then
  auth_args+=(-H "x-amz-security-token: ${S3_SESSION_TOKEN}")
fi
route_args=(--noproxy '*' --connect-to "${S3_CLIENT_HOST}:443:${LB_IP}:${LISTEN_PORT}")

tmpdir="$(mktemp -d)"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
source_key="${OBJECT_PREFIX}/${run_id}/source.bin"
copy_key="${OBJECT_PREFIX}/${run_id}/copy.bin"
empty_key="${OBJECT_PREFIX}/${run_id}/empty.bin"
base_url="https://${S3_CLIENT_HOST}"
created_keys=("")

cleanup() {
  local key
  for key in "${created_keys[@]}"; do
    [ -n "$key" ] || continue
    curl -sS -o /dev/null -X DELETE "${route_args[@]}" "${auth_args[@]}" \
      "${base_url}/${key}" >/dev/null 2>&1 || true
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT

PASS=0
pass() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail_response() {
  local label="$1"
  local code="$2"
  local response_file="$3"
  printf '  [FAIL] %s: HTTP %s\n' "$label" "$code" >&2
  sed -n '1,20p' "$response_file" >&2
  exit 1
}
expect_code() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local response_file="$4"
  [ "$actual" = "$expected" ] || fail_response "$label" "$actual" "$response_file"
  pass "${label}: HTTP ${actual}"
}

printf 'S3 L4 functional test: %s:443 -> %s:%s\n' \
  "$S3_CLIENT_HOST" "$LB_IP" "$LISTEN_PORT"

payload="$tmpdir/source.bin"
download="$tmpdir/download.bin"
range_body="$tmpdir/range.bin"
body="$tmpdir/body.out"
headers="$tmpdir/headers.out"
printf 's3-l4-functional-%s\nsecond-line\n' "$run_id" > "$payload"

code="$(curl -sS -o "$body" -w '%{http_code}' -X PUT \
  "${route_args[@]}" "${auth_args[@]}" \
  -H 'x-amz-meta-l4-check: pass' --data-binary @"$payload" \
  "${base_url}/${source_key}")"
expect_code "PUT object" 200 "$code" "$body"
created_keys+=("$source_key")

code="$(curl -sS -o "$download" -w '%{http_code}' \
  "${route_args[@]}" "${auth_args[@]}" "${base_url}/${source_key}")"
expect_code "GET object" 200 "$code" "$download"
cmp -s "$payload" "$download" || { echo "  [FAIL] GET checksum mismatch" >&2; exit 1; }
pass "GET payload checksum matches"

code="$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' -I \
  "${route_args[@]}" "${auth_args[@]}" "${base_url}/${source_key}")"
expect_code "HEAD object" 200 "$code" "$body"
grep -Eiq '^x-oss-meta-l4-check:[[:space:]]*pass|^x-amz-meta-l4-check:[[:space:]]*pass' "$headers" \
  || { echo "  [FAIL] metadata missing from HEAD response" >&2; exit 1; }
pass "custom metadata preserved"

code="$(curl -sS -o "$range_body" -w '%{http_code}' \
  "${route_args[@]}" "${auth_args[@]}" -H 'Range: bytes=0-7' \
  "${base_url}/${source_key}")"
expect_code "Range GET" 206 "$code" "$range_body"
[ "$(wc -c < "$range_body" | tr -d ' ')" = "8" ] \
  || { echo "  [FAIL] Range GET returned the wrong length" >&2; exit 1; }
pass "Range GET returned 8 bytes"

code="$(curl -sS -o "$body" -w '%{http_code}' -X PUT \
  "${route_args[@]}" "${auth_args[@]}" --data-binary '' \
  "${base_url}/${empty_key}")"
expect_code "PUT zero-byte object" 200 "$code" "$body"
created_keys+=("$empty_key")

code="$(curl -sS -o "$body" -w '%{http_code}' \
  "${route_args[@]}" "${auth_args[@]}" \
  "${base_url}/?list-type=2&prefix=${OBJECT_PREFIX}%2F${run_id}%2F")"
expect_code "ListObjectsV2" 200 "$code" "$body"
grep -q "$source_key" "$body" || { echo "  [FAIL] source object missing from listing" >&2; exit 1; }
pass "ListObjectsV2 includes uploaded object"

code="$(curl -sS -o "$body" -w '%{http_code}' -X PUT \
  "${route_args[@]}" "${auth_args[@]}" \
  -H "x-amz-copy-source: /${S3_BUCKET}/${source_key}" \
  "${base_url}/${copy_key}")"
expect_code "CopyObject" 200 "$code" "$body"
created_keys+=("$copy_key")

code="$(curl -sS -o "$download" -w '%{http_code}' \
  "${route_args[@]}" "${auth_args[@]}" "${base_url}/${copy_key}")"
expect_code "GET copied object" 200 "$code" "$download"
cmp -s "$payload" "$download" || { echo "  [FAIL] copied payload mismatch" >&2; exit 1; }
pass "CopyObject payload checksum matches"

for key in "$copy_key" "$empty_key" "$source_key"; do
  code="$(curl -sS -o "$body" -w '%{http_code}' -X DELETE \
    "${route_args[@]}" "${auth_args[@]}" "${base_url}/${key}")"
  expect_code "DELETE ${key##*/}" 204 "$code" "$body"
done
created_keys=("")

printf 'Summary: PASS=%s FAIL=0\n' "$PASS"
