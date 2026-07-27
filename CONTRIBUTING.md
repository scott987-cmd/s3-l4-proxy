# Contributing

## Ground rules

This toolkit's value is in what it deliberately does **not** do. Two properties are not negotiable:

1. **The proxy never terminates TLS.** No `ssl`, `ssl_certificate`, or `ssl_certificate_key` in any stream config.
2. **The proxy never holds storage credentials.** No AK/SK, token, or signing material on the proxy path.

A change that breaks either one is out of scope here. CI enforces both.

A third rule follows from experience rather than design: **the upstream must not be a variable.** `proxy_pass $host` puts nginx on the runtime resolver path and causes periodic connection resets. Use the fixed `upstream s3_backend` block; DNS changes are handled by the reload timer.

## Before opening a pull request

```bash
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck --severity=warning scripts/*.sh
```

CI additionally renders the stream template, runs `nginx -t` against it, and scans the tree for credentials. All of it runs on Ubuntu — see [.github/workflows/ci.yml](.github/workflows/ci.yml).

## Testing a real change

Static checks cannot prove a proxy change works. If you touch `configure_l4_proxy.sh`, the templates, or anything in the data path, run it on a disposable VM against a real S3-compatible endpoint:

```bash
cp config.example.env config.env      # fill in a real backend
sudo bash scripts/install_l4_proxy.sh CONFIG=config.env
bash scripts/verify_l4_proxy.sh -c config.env

S3_ACCESS_KEY=... S3_SECRET_KEY=... \
  bash scripts/acceptance_l4_proxy.sh CONFIG=config.env RUN_SPEED=1
```

Say in the pull request which distribution, nginx version, and backend you tested against. "Renders fine" is not a test result.

## Style

- Bash with `set -euo pipefail` (verification scripts use `set -uo pipefail` so they can count failures instead of aborting).
- New settings are environment variables with a default, documented in [docs/CONFIGURATION.md](docs/CONFIGURATION.md) and added to `config.example.env` with a comment.
- Anything that writes to the system must back up first and be covered by the rollback path in `configure_l4_proxy.sh`.
- Destructive-sounding help text must match what the code actually does. A help string that overstates the blast radius is a bug.

## Adding vendor support

The data path is vendor-neutral, so "support" means documentation plus a verification note, not new code. Open a pull request that adds a row to the compatibility table with the endpoint family, signing algorithm, and what you actually ran (PUT/GET/HEAD/multipart + integrity check). Do not mark a vendor verified from a design argument.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).
