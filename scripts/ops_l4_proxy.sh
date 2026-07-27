#!/usr/bin/env bash
set -euo pipefail

CONFIG=""
ACTION="${1:-status}"
[ $# -gt 0 ] && shift || true

for argument in "$@"; do
  case "$argument" in
    CONFIG=*) CONFIG="${argument#*=}" ;;
    *) ;;
  esac
done

if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

S3_REGION="${S3_REGION:-${REGION:-cn-beijing}}"
S3_BACKEND_HOST="${S3_BACKEND_HOST:-${TOS_ENDPOINT:-tos-s3-${S3_REGION}.ivolces.com}}"
S3_BACKEND_PORT="${S3_BACKEND_PORT:-443}"
LISTEN_PORT="${LISTEN_PORT:-443}"
CONF_PATH="${CONF_PATH:-/etc/nginx/stream.d/s3-proxy.conf}"
LOG_FILE="${LOG_FILE:-/var/log/nginx/s3-stream.log}"
NOFILE="${NOFILE:-65535}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/ops_l4_proxy.sh <action> [CONFIG=config.env]

Actions:
  status        Show service, listener, config, and upstream summary
  health        Run verify_l4_proxy.sh
  reload        nginx -t and reload
  restart       Restart nginx
  logs          Tail stream logs
  conns         Show TCP connection summary for LISTEN_PORT
  upstream      Resolve and test S3 backend
  config        Print active stream config
  nofile        Apply worker/systemd nofile limit
  unlock-egress Remove the dedicated S3_L4_EGRESS chain; existing OUTPUT rules are untouched
USAGE
}

run_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$@"
  else
    return 1
  fi
}

case "$ACTION" in
  -h|--help|help)
    usage
    ;;
  status)
    echo "== nginx service =="
    run_systemctl status nginx --no-pager || pgrep -a nginx || true
    echo
    echo "== listeners =="
    ss -tlnp 2>/dev/null | grep -E ":(${LISTEN_PORT}|80|22) " || true
    echo
    echo "== upstream =="
    getent hosts "$S3_BACKEND_HOST" || true
    echo
    echo "== stream config =="
    [ -f "$CONF_PATH" ] && sed -n '1,220p' "$CONF_PATH" || echo "missing $CONF_PATH"
    ;;
  health)
    root_dir="$(cd "$(dirname "$0")/.." && pwd)"
    bash "$root_dir/scripts/verify_l4_proxy.sh" -c "${CONFIG:-/dev/null}"
    ;;
  reload)
    nginx -t
    run_systemctl reload nginx || nginx -s reload
    echo "nginx reloaded"
    ;;
  restart)
    run_systemctl restart nginx || { nginx -s stop 2>/dev/null || true; nginx; }
    echo "nginx restarted"
    ;;
  logs)
    lines="${LINES:-100}"
    if [ -f "$LOG_FILE" ]; then
      tail -n "$lines" -f "$LOG_FILE"
    else
      tail -n "$lines" -f /var/log/nginx/*.log
    fi
    ;;
  conns)
    echo "== by state =="
    ss -tan 2>/dev/null | awk -v port=":${LISTEN_PORT}" '$4 ~ port || $5 ~ port {count[$1]++} END {for (s in count) print s,count[s]}'
    echo
    echo "== established peers =="
    ss -tn state established 2>/dev/null | awk -v port=":${LISTEN_PORT}" '$4 ~ port || $5 ~ port {print}' | head -50
    ;;
  upstream)
    echo "== DNS =="
    getent hosts "$S3_BACKEND_HOST"
    echo
    echo "== HTTPS probe =="
    curl -sk --connect-timeout 5 --max-time 8 -o /dev/null \
      -w 'http=%{http_code} remote=%{remote_ip} connect=%{time_connect} total=%{time_total}\n' \
      "https://${S3_BACKEND_HOST}:${S3_BACKEND_PORT}/" || true
    ;;
  config)
    nginx -T 2>/dev/null | sed -n '/stream {/,/}# configuration file/p' || sed -n '1,220p' "$CONF_PATH"
    ;;
  nofile)
    if grep -qE '^[[:space:]]*worker_rlimit_nofile' /etc/nginx/nginx.conf; then
      sed -i.bak_nofile -E "s/^[[:space:]]*worker_rlimit_nofile.*/worker_rlimit_nofile ${NOFILE};/" /etc/nginx/nginx.conf
    else
      cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak_nofile.$(date +%Y%m%d%H%M%S)"
      { printf 'worker_rlimit_nofile %s;\n' "$NOFILE"; cat /etc/nginx/nginx.conf; } > /etc/nginx/nginx.conf.tmp
      mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
    fi
    mkdir -p /etc/systemd/system/nginx.service.d
    { echo "[Service]"; echo "LimitNOFILE=${NOFILE}"; } > /etc/systemd/system/nginx.service.d/limits.conf
    run_systemctl daemon-reload || true
    nginx -t
    echo "nofile configured; restart nginx to apply process limit"
    ;;
  unlock-egress)
    if command -v iptables >/dev/null 2>&1; then
      chain="${FIREWALL_CHAIN:-S3_L4_EGRESS}"
      iptables -D OUTPUT -j "$chain" 2>/dev/null || true
      iptables -F "$chain" 2>/dev/null || true
      iptables -X "$chain" 2>/dev/null || true
      echo "dedicated egress chain removed: $chain"
    else
      echo "iptables not found"
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
