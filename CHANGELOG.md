# Changelog

All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- `verify_l4_proxy.sh`: `-e` and `-p` were silently overridden when `-c config.env` also defined `S3_BACKEND_HOST` or `LISTEN_PORT`, because the config file was sourced after option parsing. Explicit flags now win over the config file, as the usage text always claimed.
- `ops_l4_proxy.sh`: the `--help` text described `unlock-egress` as "Restore OUTPUT policy to ACCEPT and flush OUTPUT chain". The implementation never did that — it removes only the dedicated `S3_L4_EGRESS` chain and leaves existing `OUTPUT` rules alone. The help text now matches the (safe) behavior.

### Added

- Continuous integration: script parsing, ShellCheck, executable-bit check, stream template rendering with a real `nginx -t`, guards against variable `proxy_pass` and TLS termination in the stream config, and a credential scan over the whole tree.
- Documentation: configuration reference, operations runbook, troubleshooting guide, security policy, contributing guide, and a Chinese README.
- Published documentation site under `docs/`, including an architecture diagram, a five-layer security boundary, a deploy/inspect/accept/operate flow and a change-and-rollback flowchart.
- `DISCLAIMER.md`, covering warranty, performance figures, system-state changes, pre-production validation, security and compliance responsibility, and vendor non-affiliation. Summarised in both READMEs and on the documentation site.

### Changed

- Terminology is vendor-neutral: the frontend is described as a public load balancer with an L4 TCP listener rather than by any one vendor's product name. `LB_IP` is the current variable name; `CLB_IP` and `EIP` still work.
- Chinese is now the repository's default language: `README.md` is Chinese and the English version moved to `README.en.md`.
- The L4-versus-L7 comparison was removed from this solution's material. The design now argues its own case on performance, stability, operating effort and cost, and the security section states why the boundary is sufficient for most deployments rather than listing what it does not do.
- Documentation is now vendor-neutral. `S3_BACKEND_HOST` still defaults to a Volcengine TOS endpoint for backward compatibility; that default is documented explicitly rather than assumed.

## [1.0.0] — 2026-07-27

Initial public release of the L4 TCP passthrough toolkit.

### Added

- One-command deploy (`install_l4_proxy.sh`), inspection (`verify_l4_proxy.sh`), acceptance (`acceptance_l4_proxy.sh`), day-2 operations (`ops_l4_proxy.sh`), and delivery packaging (`package_l4_proxy.sh`).
- nginx `stream` passthrough with a fixed upstream, replacing an earlier variable `proxy_pass` that caused connection resets at roughly 5-second intervals.
- nginx installation and dynamic stream module handling for CentOS/RHEL and Debian/Ubuntu.
- Pre-change backup of nginx config, stream config, systemd limits, logrotate, sysctl and iptables, with automatic rollback when any step or `nginx -t` fails.
- Dedicated `S3_L4_EGRESS` firewall chain that never flushes existing `OUTPUT` rules, off by default and reversible.
- `s3-l4-dns-reload.timer` for graceful reloads so a fixed upstream still picks up backend DNS changes.
- Optional PROXY protocol support, off by default, with a consistency check between the config value and the rendered listener.
- Credential scan in the packaging step that fails the build on key-shaped strings or private keys.

### Verified

Deployed from the release archive on a freshly reinstalled CentOS Stream 9 host with nginx 1.20.1 and the dynamic stream module: inspection `PASS=20 WARN=1 FAIL=0` (the single warning is the egress lock being off by security default). End-to-end through a public load balancer against Volcengine TOS: 1 MB PUT 200, GET 200, MD5 match. Larger objects (100 MB / 500 MB, single connection) reached roughly 78–98 MB/s, close to the test instance NIC ceiling. `DELETE` returned 403, matching the least-privilege test credential.
