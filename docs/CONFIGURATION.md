# Configuration reference

Every setting is an environment variable. Scripts read them in this order, later wins:

1. Built-in default
2. `config.env` (via `CONFIG=config.env`, sourced by the script)
3. `KEY=VALUE` arguments on the command line
4. Exported environment variables for the credential-only settings

> `verify_l4_proxy.sh` is the exception: it takes `-c` / `-e` / `-p` flags, and an explicit `-e` / `-p` flag wins over the config file.

Start from the shipped template:

```bash
cp config.example.env config.env
```

Never commit `config.env` — `.gitignore` blocks it.

## Backend and client identity

| Variable | Default | Meaning |
| --- | --- | --- |
| `S3_BACKEND_HOST` | `tos-s3-<S3_REGION>.ivolces.com` | Object storage endpoint the ECS host connects to. **Use the private endpoint in production.** The default is Volcengine TOS — set it explicitly for any other vendor. |
| `S3_BACKEND_PORT` | `443` | Backend TCP port. |
| `S3_CLIENT_HOST` | *(empty)* | Hostname the client uses for TLS SNI and request signing. Must be covered by the backend certificate. Also the host used by verification probes. |
| `S3_REGION` | `cn-beijing` | Region for SigV4 in the verification scripts. The proxy itself is region-agnostic. |
| `S3_SERVICE` | `s3` | SigV4 service name for verification scripts. |
| `S3_SIGV4_PROVIDER` | `aws:amz` | curl `--aws-sigv4` provider prefix. |
| `LB_IP` | *(empty)* | load balancer VIP/EIP. Only used by client-side diagnostics and the speed test; the proxy never needs it. |

## Listener and nginx layout

| Variable | Default | Meaning |
| --- | --- | --- |
| `LISTEN_PORT` | `443` | Port the nginx stream server listens on. Must match the load balancer backend port and its health check. |
| `NGINX_MAIN` | `/etc/nginx/nginx.conf` | Path to the nginx main config. |
| `NGINX_USER` | auto-detected | nginx worker user. Auto-detects `nginx`, then `www-data`; the run aborts if neither exists. |
| `STREAM_DIR` | `/etc/nginx/stream.d` | Directory included from the `stream {}` block. |
| `CONF_PATH` | `$STREAM_DIR/s3-proxy.conf` | Generated stream config file. |
| `LEGACY_CONF_PATH` | `$STREAM_DIR/tos-proxy.conf` | Older config path. If found and recognized as previously managed, it is renamed with a `.migrated.<timestamp>` suffix; if unrecognized, the run aborts rather than clobbering it. |
| `MAIN_MODE` | `replace` | `replace` installs the known-good stream-only main config (after backup). `auto` only appends a `stream { include ... }` block, preserving existing HTTP config. |
| `DEDICATED_PROXY_HOST` | `1` | `1` treats the host as proxy-only. Set to `0` together with `MAIN_MODE=auto` when co-locating with an existing nginx HTTP service. |
| `ENABLE_PROXY_PROTOCOL` | `0` | Set to `1` **only** when the load balancer listener also sends PROXY protocol. A mismatch breaks every plain TLS client. When enabled, the access log records `$proxy_protocol_addr` instead of `$remote_addr`. |

## Installation behavior

| Variable | Default | Meaning |
| --- | --- | --- |
| `INSTALL_NGINX` | `1` | Set to `0` on hosts where nginx comes from a base image or another provisioning system; the run then aborts if nginx is missing. |
| `WITH_STREAM` | `1` | Allow installing the `nginx-mod-stream` / `libnginx-mod-stream` package. `0` aborts instead when the module is missing. |
| `VERIFY_AFTER_INSTALL` | `1` | Run `verify_l4_proxy.sh` at the end of the install. Warnings do not fail the install; failures do. |

## Hardening and runtime baseline

| Variable | Default | Meaning |
| --- | --- | --- |
| `HARDEN` | `1` | Apply nofile limits, sysctl, logrotate, DNS reload timer, and the egress chain step. |
| `NOFILE` | `65535` | `worker_rlimit_nofile` and systemd `LimitNOFILE`. |
| `APPLY_SYSCTL` | `1` | Install the network sysctl baseline to `/etc/sysctl.d/99-s3-l4-proxy.conf`. |
| `INSTALL_DNS_RELOAD_TIMER` | `1` | Install and enable `s3-l4-dns-reload.timer`. |
| `DNS_RELOAD_INTERVAL` | `5min` | Timer interval — any systemd time span (`30s`, `5min`, `1h`). |
| `BACKUP_ROOT` | `/var/backups/s3-l4-proxy` | Where per-run backups are written before any change. |
| `EGRESS_LOCK` | `0` | `1` builds the `S3_L4_EGRESS` chain allowing only established traffic, loopback, SSH, DNS, `EXTRA_ALLOW`, and the resolved backend IPs — everything else is rejected. **Off by default so it cannot strand a host.** |
| `EGRESS_UNLOCK` | `0` | `1` removes the chain and skips all other hardening for that run. |
| `FIREWALL_CHAIN` | `S3_L4_EGRESS` | Name of the dedicated iptables chain. Existing `OUTPUT` rules are never flushed. |
| `SSH_PORT` | `22` | Port kept open by the egress lock so you cannot lock yourself out. |
| `EXTRA_ALLOW` | *(empty)* | Comma-separated extra egress destinations (monitoring, package mirrors, NTP). Add these **before** enabling the lock. |

## Verification and testing

| Variable | Default | Meaning |
| --- | --- | --- |
| `RUN_SPEED` | `0` | `1` makes acceptance run a real PUT/GET/MD5 through the load balancer. Requires `LB_IP`, `S3_CLIENT_HOST` and credentials. |
| `SIZE_MB` | `100` | Test object size. The example config ships `100`; use a large object for any capacity claim. |
| `OBJECT_PREFIX` | `l4-proxy-test` | Test object key prefix. |
| `LOG_FILE` | `/var/log/nginx/s3-stream.log` | Log tailed by `ops_l4_proxy.sh logs`. |
| `LINES` | `100` | Lines shown by `ops_l4_proxy.sh logs`. |
| `WARN_EXTRA_PORTS` | `1` | Warn when ports other than `LISTEN_PORT`/22 are listening. |

## Credentials

Credentials are **never** read from `config.env`. Pass them in the environment of the test process only:

| Variable | Meaning |
| --- | --- |
| `S3_ACCESS_KEY` | Access key for verification scripts. |
| `S3_SECRET_KEY` | Secret key for verification scripts. |
| `S3_SESSION_TOKEN` | Optional STS token, sent as `x-amz-security-token`. |

```bash
S3_ACCESS_KEY=... S3_SECRET_KEY=... bash scripts/acceptance_l4_proxy.sh CONFIG=config.env RUN_SPEED=1
```

> `speed_test_l4.sh` hands these to `curl --aws-sigv4 --user`, so they appear in the process list while the test runs. Use a dedicated least-privilege test credential and avoid running it on a shared host. See [SECURITY.md](../SECURITY.md).

## Legacy aliases

Accepted for backward compatibility with earlier TOS-specific deployments. Prefer the new names.

| Legacy | Current |
| --- | --- |
| `TOS_ENDPOINT` | `S3_BACKEND_HOST` |
| `REGION` | `S3_REGION` |
| `EIP` | `LB_IP` |
| `VHOST` | `S3_CLIENT_HOST` |
| `TOS_AK`, `AK` | `S3_ACCESS_KEY` |
| `TOS_SK`, `SK` | `S3_SECRET_KEY` |

## Worked examples

Dedicated proxy host in front of Volcengine TOS:

```bash
S3_BACKEND_HOST=tos-s3-cn-beijing.ivolces.com
S3_BACKEND_PORT=443
S3_CLIENT_HOST=private-proxy.tos-s3-cn-beijing.volces.com
S3_REGION=cn-beijing
LISTEN_PORT=443
MAIN_MODE=replace
DEDICATED_PROXY_HOST=1
```

Co-located with an existing nginx serving HTTP:

```bash
MAIN_MODE=auto
DEDICATED_PROXY_HOST=0
LISTEN_PORT=8443          # avoid colliding with the existing 443 listener
STREAM_DIR=/etc/nginx/stream.d
```

AWS S3 via a VPC endpoint:

```bash
S3_BACKEND_HOST=bucket.vpce-0abc123.s3.cn-north-1.vpce.amazonaws.com.cn
S3_CLIENT_HOST=bucket.s3.cn-north-1.amazonaws.com.cn
S3_REGION=cn-north-1
S3_SERVICE=s3
```
