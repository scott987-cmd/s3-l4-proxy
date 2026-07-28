#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-}"
RUN_SPEED="${RUN_SPEED:-0}"
RUN_FUNCTIONAL="${RUN_FUNCTIONAL:-0}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/acceptance_l4_proxy.sh CONFIG=config.env [RUN_FUNCTIONAL=1] [RUN_SPEED=1]

Runs production acceptance checks:
  1. node health and nginx stream config
  2. local ECS passthrough to the private S3-compatible backend
  3. optional load balancer diagnostics when LB_IP is configured
  4. optional small-object S3 functional test when RUN_FUNCTIONAL=1 and AK/SK are set
  5. optional S3 PUT/GET/MD5 speed test when RUN_SPEED=1 and AK/SK are set
USAGE
}

for argument in "$@"; do
  case "$argument" in
    -h|--help) usage; exit 0 ;;
    CONFIG=*) CONFIG="${argument#*=}" ;;
    RUN_FUNCTIONAL=*) RUN_FUNCTIONAL="${argument#*=}" ;;
    RUN_SPEED=*) RUN_SPEED="${argument#*=}" ;;
    *) ;;
  esac
done

[ -n "$CONFIG" ] || { usage; exit 2; }
[ -f "$CONFIG" ] || { echo "[accept][ERR] config not found: $CONFIG"; exit 2; }

# shellcheck disable=SC1090
source "$CONFIG"

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-}}"
S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
S3_CLIENT_HOST="${S3_CLIENT_HOST:-${VHOST:-}}"
LISTEN_PORT="${LISTEN_PORT:-443}"
CLB_IP="${LB_IP:-${CLB_IP:-${EIP:-}}}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-${TOS_AK:-${AK:-}}}"
S3_SECRET_KEY="${S3_SECRET_KEY:-${TOS_SK:-${SK:-}}}"
S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-}"

PASS=0
WARN=0
FAIL=0

ok() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$*"; }

step "1. Node health"
if bash "$ROOT/scripts/verify_l4_proxy.sh" -c "$CONFIG"; then
  ok "verify_l4_proxy passed"
else
  code=$?
  if [ "$code" -eq 1 ]; then
    warn "verify_l4_proxy has warnings"
  else
    bad "verify_l4_proxy failed"
  fi
fi

step "2. Local passthrough"
probe_host="${S3_CLIENT_HOST:-$S3_BACKEND_HOST}"
code="$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 8 -o /dev/null -w '%{http_code}' \
  --connect-to "${probe_host}:443:127.0.0.1:${LISTEN_PORT}" \
  "https://${probe_host}/" 2>/dev/null || echo 000)"
case "$code" in
  200|301|302|307|400|401|403|404|405) ok "local passthrough reached S3 backend: HTTP $code" ;;
  *) bad "local passthrough failed: HTTP $code" ;;
esac

step "3. Load balancer diagnostics"
if [ -n "$CLB_IP" ]; then
  CLB_IP="$CLB_IP" LISTEN_PORT="$LISTEN_PORT" S3_CLIENT_HOST="$S3_CLIENT_HOST" S3_BACKEND_HOST="$S3_BACKEND_HOST" S3_BACKEND_PORT="$S3_BACKEND_PORT" \
    bash "$ROOT/scripts/diag_clb_l4.sh" || warn "load balancer diagnostic returned non-zero"
else
  warn "LB_IP not configured; skip load balancer diagnostics"
fi

step "4. Optional S3 functional test"
if [ "$RUN_FUNCTIONAL" = "1" ]; then
  if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_CLIENT_HOST" ] && [ -n "$CLB_IP" ]; then
    CLB_IP="$CLB_IP" LISTEN_PORT="$LISTEN_PORT" S3_CLIENT_HOST="$S3_CLIENT_HOST" S3_REGION="$S3_REGION" \
      S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET_KEY="$S3_SECRET_KEY" S3_SESSION_TOKEN="$S3_SESSION_TOKEN" \
      bash "$ROOT/scripts/functional_test_l4.sh"
    ok "functional test passed"
  else
    bad "RUN_FUNCTIONAL=1 requires LB_IP, S3_CLIENT_HOST, and S3_ACCESS_KEY/S3_SECRET_KEY"
  fi
else
  warn "RUN_FUNCTIONAL!=1; skip S3 functional test"
fi

step "5. Optional S3 speed test"
if [ "$RUN_SPEED" = "1" ]; then
  if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_CLIENT_HOST" ] && [ -n "$CLB_IP" ]; then
    CLB_IP="$CLB_IP" LISTEN_PORT="$LISTEN_PORT" S3_CLIENT_HOST="$S3_CLIENT_HOST" S3_REGION="$S3_REGION" \
      S3_ACCESS_KEY="$S3_ACCESS_KEY" S3_SECRET_KEY="$S3_SECRET_KEY" S3_SESSION_TOKEN="$S3_SESSION_TOKEN" \
      bash "$ROOT/scripts/speed_test_l4.sh"
    ok "speed test passed"
  else
    bad "RUN_SPEED=1 requires LB_IP, S3_CLIENT_HOST, and S3_ACCESS_KEY/S3_SECRET_KEY"
  fi
else
  warn "RUN_SPEED!=1; skip S3 PUT/GET speed test"
fi

printf '\n== Summary ==\n'
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 2
elif [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
