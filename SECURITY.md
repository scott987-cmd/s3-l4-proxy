# Security

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/scott987-cmd/s3-l4-proxy/security/advisories/new) rather than a public issue. Please include the affected script or template, the configuration that triggers it, and the impact you observed.

## Threat model

This toolkit deploys a **transparent** TCP proxy. It is designed so that compromising the proxy host yields as little as possible:

| Asset | Exposure on the proxy |
| --- | --- |
| Object data | **Ciphertext only.** TLS is never terminated here. |
| Storage credentials | **None.** No AK/SK, token or signing key is stored or read by the proxy path. |
| TLS private keys | **None.** No certificate or key material is installed. |
| Object metadata (bucket, key, action) | **Not visible.** The proxy sees encrypted bytes; the log records connection facts only. |
| Network reachability | The real asset. A compromised host can reach the storage private endpoint. |

Because reachability is what the proxy actually holds, the controls below focus on narrowing it.

## Controls

| Layer | Control | Requirement |
| --- | --- | --- |
| Data | Client-side encryption | Encrypt sensitive data with your own KMS before it leaves the client side. |
| Transport | End-to-end TLS | The CLB listener must be TCP. A TLS-terminating listener silently breaks this property. |
| Ingress | CLB ACL + security group | Allow only the client's fixed egress IPs to the CLB; allow ECS `LISTEN_PORT` only from the CLB. |
| Proxy host | Port and egress narrowing | Dedicated host, `LISTEN_PORT` and SSH only. Optional `EGRESS_LOCK=1` restricts outbound to DNS, SSH, `EXTRA_ALLOW`, and the resolved backend. |
| Storage | Least privilege | A dedicated sub-account/role scoped to one bucket and only the required actions. Grant `DeleteObject` only when the workload needs it. |
| Storage | Source restriction | Pin the bucket policy to the proxy's **real** source address. |

### Getting the source address right

Under L4 the storage sees the address the ECS host uses to reach the private endpoint — **not** the original client's egress IP, and not necessarily the ECS public IP. Read the actual value from the storage audit log before writing an IP condition into a bucket policy. Guessing here either fails open (too broad) or locks out production.

Do not add a blanket `Deny + Principal:"*" + NotIpAddress` rule as a belt-and-braces measure. Implicit deny already covers the default case, and an explicit `Deny` overrides every `Allow` — including the ones you still need.

## Why this is enough for most deployments

Authorization and object-level audit have their authoritative home in the object storage itself — IAM principals, bucket policies and audit logs all take effect there, in full. Not re-implementing them at the proxy layer does not make them absent.

The reverse is what actually costs security. Any design that decrypts mid-path adds a component holding both plaintext and keys: one more place that must be defended, rotated, patched and audited, and one more place where a compromise yields data. This design decrypts nothing, holds no credential and stores no private key. An attacker who takes the proxy host gets neither the objects nor the keys — only network reachability that the CLB ACL, the security group and the bucket policy have already narrowed three times over.

## What the proxy layer does not enforce

L4 has no visibility into encrypted HTTP, so these are not enforced *at the proxy*:

- object-level authorization or per-tenant access control
- object-level audit (who read which key)
- rate limiting by bucket, key, or action
- WAF header/body inspection or content scanning
- credential translation, brokering, or re-signing

The first two are normally covered by the storage's own IAM and audit log, which is why most deployments need nothing further. A deployment that must additionally enforce the rest *inside the network path* needs a control outside this design — do not attempt to approximate one with TCP-level rules.

## Known operational risks

**Credentials in the process list.** `speed_test_l4.sh` passes `S3_ACCESS_KEY`/`S3_SECRET_KEY` to `curl --aws-sigv4 --user`, so they are visible in `ps` for the duration of the test. Mitigations, in order of preference:

1. Use a dedicated least-privilege test credential, rotated after acceptance.
2. Run acceptance on a host you control, not a shared bastion.
3. Prefer short-lived STS credentials via `S3_SESSION_TOKEN`.

Verification credentials are never written to disk and never read from `config.env`.

**PROXY protocol mismatch.** Enabling `ENABLE_PROXY_PROTOCOL` on one side only breaks every plain TLS client. It is off by default; `verify_l4_proxy.sh` fails on a mismatch between the config value and the rendered listener.

**Egress lock lockout.** `EGRESS_LOCK=1` rejects outbound traffic that is not explicitly allowed, which can cut off monitoring agents or package mirrors. It is off by default, keeps SSH open, uses a dedicated `S3_L4_EGRESS` chain that never flushes existing `OUTPUT` rules, and is reversible with `ops_l4_proxy.sh unlock-egress`. Enumerate dependencies in `EXTRA_ALLOW` before enabling it.

**`MAIN_MODE=replace` on a shared host.** The default replaces the nginx main config, which is correct for a dedicated proxy and wrong for a host also serving HTTP. Set `MAIN_MODE=auto` and `DEDICATED_PROXY_HOST=0` there. A backup is always taken first.

## Secret hygiene in this repository

- `config.example.env` contains placeholders only; real values belong in `config.env`, which `.gitignore` blocks.
- `package_l4_proxy.sh` scans the staged archive for key-shaped strings and private-key headers and **fails the build** on a hit.
- CI runs the same scan on every push and pull request.
- No credential, certificate, private key, real IP address, or internal hostname is committed to this repository.
