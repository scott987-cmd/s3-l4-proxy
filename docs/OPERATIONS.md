# Operations runbook

Day-2 procedures for a deployed L4 proxy fleet. Every command assumes you are in the repo directory on the proxy node with a filled-in `config.env`.

## Daily / on-call quick checks

```bash
bash scripts/ops_l4_proxy.sh status CONFIG=config.env    # service, listener, upstream, active config
bash scripts/ops_l4_proxy.sh health CONFIG=config.env    # full verification, exit 0/1/2
bash scripts/ops_l4_proxy.sh conns  CONFIG=config.env    # connection states and peers
```

`health` is the one to wire into monitoring: exit `0` pass, `1` warnings, `2` failures.

## What to alert on

| Dimension | Signal | Threshold |
| --- | --- | --- |
| Liveness | nginx active, `LISTEN_PORT` listening, healthy load balancer backends | Any node down, or healthy backends below N+1 |
| Connections | ESTABLISHED, TIME_WAIT, connect failures | Above 80% of designed capacity |
| Throughput | NIC in/out bps, stream bytes | Sustained near 80% of instance bandwidth |
| Latency | `ct=` (upstream connect time), `sess=` (session time) in the stream log | Connect P99 above the capacity baseline |
| Resources | CPU, memory, file handles, packet loss | CPU or open handles above 80% |
| Timer | `s3-l4-dns-reload.timer` active | Inactive for more than one interval |

The stream access log is `/var/log/nginx/s3-stream.log`, rotated daily with 15 generations kept:

```
$remote_addr [$time_local] $protocol $status sent=$bytes_sent recv=$bytes_received sess=$session_time up=$upstream_addr ct=$upstream_connect_time
```

With `ENABLE_PROXY_PROTOCOL=1` the first field is `$proxy_protocol_addr` — the real client address instead of the load balancer's.

## Routine procedures

### Reload after a backend DNS change

The timer does this automatically every `DNS_RELOAD_INTERVAL`. To force it:

```bash
sudo bash scripts/ops_l4_proxy.sh reload CONFIG=config.env
```

`reload` runs `nginx -t` first and does not reload a config that fails the test.

### Add a node

The proxy is stateless — there is no session state to migrate.

```bash
# on the new host
cp config.example.env config.env      # same values as the existing nodes
sudo bash scripts/install_l4_proxy.sh CONFIG=config.env
bash scripts/verify_l4_proxy.sh -c config.env
```

Then add it to the load balancer backend group and wait for the health check to go green before counting it toward capacity.

### Remove a node

Drain at the load balancer first (remove from the backend group, let connections finish — `proxy_timeout` is 600s, so long transfers need that much grace), then stop nginx.

### Change the backend endpoint

```bash
# edit S3_BACKEND_HOST in config.env, then on each node in turn:
sudo bash scripts/configure_l4_proxy.sh CONFIG=config.env
bash scripts/verify_l4_proxy.sh -c config.env
```

Do one node at a time and confirm load balancer health between nodes. The script backs up and auto-rolls-back on failure.

### Certificate rotation at the storage side

Nothing to do on the proxy — it holds no certificates and does not terminate TLS. Only confirm the new certificate still covers `S3_CLIENT_HOST`, then re-run acceptance.

## Capacity

- Plan by peak bandwidth, concurrent connections, and single-NIC ceiling, with N+1 headroom.
- Single-connection throughput is normally bounded by the instance NIC, not by nginx.
- Small-object tests measure round trips, not capacity. Use `SIZE_MB=100` or larger for any capacity claim.

```bash
S3_ACCESS_KEY=... S3_SECRET_KEY=... SIZE_MB=500 \
  LB_IP=<lb-ip> S3_CLIENT_HOST=<host> S3_REGION=<region> \
  bash scripts/speed_test_l4.sh
```

## Change management

1. Change `config.env` on one node.
2. `sudo bash scripts/configure_l4_proxy.sh CONFIG=config.env` — backs up to `/var/backups/s3-l4-proxy/<timestamp>-<pid>/` before any write.
3. `bash scripts/verify_l4_proxy.sh -c config.env`.
4. Watch load balancer health and the stream log for one interval.
5. Repeat on the next node.

Automatic rollback covers nginx config, stream config, systemd limits, logrotate, sysctl, the DNS timer, and iptables. Manual rollback is in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#rolling-back-a-bad-change).

## Emergency

| Situation | Action |
| --- | --- |
| Egress lock cut off a dependency | `sudo bash scripts/ops_l4_proxy.sh unlock-egress CONFIG=config.env` — removes only the `S3_L4_EGRESS` chain |
| nginx will not start | `nginx -t` for the reason, then restore from `/var/backups/s3-l4-proxy/` |
| One node degraded | Remove from the load balancer backend group; the remaining nodes absorb traffic (this is why N+1 matters) |
| Backend unreachable from one node | `bash scripts/ops_l4_proxy.sh upstream CONFIG=config.env` — DNS result plus an HTTPS probe with timing |
| Suspected data-path problem | `bash scripts/acceptance_l4_proxy.sh CONFIG=config.env` — re-runs the full chain including local passthrough |

## Upgrading this toolkit

The scripts are idempotent — re-running `configure_l4_proxy.sh` after `git pull` re-renders the config from the current templates and backs up the previous state first. Roll node by node; nothing in the repo needs to match across nodes except `config.env`.
