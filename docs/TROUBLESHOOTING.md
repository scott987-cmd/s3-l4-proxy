# Troubleshooting

Start here:

```bash
bash scripts/verify_l4_proxy.sh -c config.env      # on the proxy node
LB_IP=<lb-ip> S3_CLIENT_HOST=<host> bash scripts/diag_clb_l4.sh   # from a client
```

`verify_l4_proxy.sh` exits `0` all pass, `1` warnings, `2` failures.

---

## Connections reset roughly every 5 seconds

**Cause.** The active stream config uses a variable upstream (`proxy_pass $something`), which puts nginx on the runtime resolver path.

**Check.**

```bash
grep -n 'proxy_pass' /etc/nginx/stream.d/s3-proxy.conf
```

**Fix.** The upstream must be a fixed `upstream s3_backend { server host:443; }` block. Re-run `configure_l4_proxy.sh`, which refuses to write a variable `proxy_pass` and fails the run if one is generated. `verify_l4_proxy.sh` also flags it as a FAIL.

---

## Every TLS client fails immediately after enabling PROXY protocol

**Cause.** `ENABLE_PROXY_PROTOCOL` and the load balancer listener disagree. If nginx expects the PROXY header and the load balancer does not send it, nginx reads the TLS ClientHello as a malformed PROXY line — and vice versa.

**Fix.** Both sides on, or both sides off. `verify_l4_proxy.sh` compares the rendered `listen` directive against `ENABLE_PROXY_PROTOCOL` and fails on a mismatch. When in doubt, set `ENABLE_PROXY_PROTOCOL=0` and disable it on the load balancer listener.

---

## TLS handshake fails through the load balancer but works on the node

**Cause.** Certificate/SNI mismatch. The client signs and SNIs with `S3_CLIENT_HOST`, and the backend certificate must cover that name. L4 cannot fix this — nothing in the path can rewrite the handshake.

**Check.**

```bash
LB_IP=<lb-ip> S3_CLIENT_HOST=<host> bash scripts/diag_clb_l4.sh   # step 2 prints subject/issuer
```

**Fix.** Use a client hostname the backend certificate covers, or ask the vendor for an equivalent endpoint/SNI pair. A load balancer listener that terminates TLS also breaks this — the listener must be TCP.

---

## `cannot connect to <backend>:443 from this host`

`configure_l4_proxy.sh` refuses to deploy a config it cannot reach.

**Check, in order.**

```bash
getent hosts "$S3_BACKEND_HOST"                  # DNS resolves at all
curl -sk -o /dev/null -w '%{http_code}\n' "https://$S3_BACKEND_HOST/"
```

**Common causes.** The private endpoint is not routable from this subnet; a security group blocks egress 443; the egress lock is on and the backend IP set changed; DNS returns a public endpoint the private network does not route.

---

## Backend DNS changed and traffic still goes to the old IP

**Cause.** By design. A fixed upstream is resolved once at start/reload — that is the tradeoff that removes the resolver resets.

**Fix.** `s3-l4-dns-reload.timer` reloads nginx every `DNS_RELOAD_INTERVAL` (default 5min). Confirm it is running:

```bash
systemctl status s3-l4-dns-reload.timer
sudo bash scripts/ops_l4_proxy.sh reload CONFIG=config.env   # force it now
```

---

## Locked out after enabling the egress lock

**Cause.** `EGRESS_LOCK=1` allows established traffic, loopback, `SSH_PORT`, DNS, `EXTRA_ALLOW` and the resolved backend IPs. Anything else — monitoring agents, package mirrors, NTP — is rejected.

**Fix.**

```bash
sudo bash scripts/ops_l4_proxy.sh unlock-egress CONFIG=config.env
```

This removes only the dedicated `S3_L4_EGRESS` chain; your other `OUTPUT` rules are untouched. Add the missing destinations to `EXTRA_ALLOW` before re-enabling.

---

## `nginx main config already has stream block`

**Cause.** `MAIN_MODE=auto` on a host that already has a `stream {}` block not pointing at `STREAM_DIR`. The script aborts rather than silently editing someone else's config.

**Fix.** Either add `include /etc/nginx/stream.d/*.conf;` to the existing `stream {}` block by hand, or use `MAIN_MODE=replace` — but only on a dedicated proxy host, since it replaces the main config (a backup is taken first).

---

## S3 returns 403 through the proxy

The proxy is transparent, so a 403 is an authorization answer from the storage, not a proxy fault. In order of likelihood:

1. **Bucket policy source IP.** Under L4 the storage sees the *proxy's* source address, not the client's. Read the real value from the storage audit log before writing the policy.
2. **Action not granted.** `DELETE=403` with `GET/PUT=200` is the expected shape of a least-privilege test credential.
3. **Signature mismatch.** Region, service, or endpoint family differ between what the client signs and what the endpoint expects.
4. **Signed host.** The signature covers the Host header; `S3_CLIENT_HOST` must be the host that was signed.

A 403 arriving at all is actually a *good* signal: TLS completed end to end and the request reached the storage.

---

## Throughput lower than expected

- A small object measures round-trip behavior, not capacity. Use `SIZE_MB=100` or larger for any capacity claim.
- Check the instance NIC ceiling first — single-connection throughput usually tops out there before nginx does.
- Check `ss -s` and the stream log's `ct=` (upstream connect time) for backend-side latency.
- Confirm you are not measuring through a saturated load balancer shared with other services.

---

## `%{exitcode}` printed literally by the diagnostic script

`diag_clb_l4.sh` uses the curl `%{exitcode}` write-out variable, which needs curl ≥ 7.75. On older distributions (CentOS 7 era) the placeholder is printed as-is. The other output lines are still valid; upgrade curl or ignore that field.

---

## Rolling back a bad change

`configure_l4_proxy.sh` backs up nginx config, stream config, systemd limits, logrotate, sysctl, the DNS timer and iptables to `/var/backups/s3-l4-proxy/<timestamp>-<pid>/` **before** touching anything, and restores all of it automatically if any step or `nginx -t` fails.

To roll back manually:

```bash
ls -t /var/backups/s3-l4-proxy/ | head
sudo cp /var/backups/s3-l4-proxy/<timestamp>/nginx.conf /etc/nginx/nginx.conf
sudo cp /var/backups/s3-l4-proxy/<timestamp>/stream.conf /etc/nginx/stream.d/s3-proxy.conf
sudo nginx -t && sudo systemctl reload nginx
```

---

## What the proxy cannot tell you

`nginx stream` sees encrypted bytes. The access log records source, duration, bytes, status and upstream — never bucket, object key, access key, or HTTP action. If you need object-level answers, get them from the client or the storage audit log. No amount of proxy configuration changes this.
