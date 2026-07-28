#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${OUTPUT:-$ROOT/dist/s3-l4-proxy.tgz}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/s3-l4-proxy/scripts" "$STAGE/s3-l4-proxy/templates" "$(dirname "$OUTPUT")"

cp "$ROOT/README.md" "$ROOT/config.example.env" "$STAGE/s3-l4-proxy/"
cp "$ROOT"/scripts/*.sh "$STAGE/s3-l4-proxy/scripts/"
cp "$ROOT"/templates/* "$STAGE/s3-l4-proxy/templates/"
chmod +x "$STAGE"/s3-l4-proxy/scripts/*.sh

if grep -RInE --exclude=README.md --exclude=package_l4_proxy.sh \
  'AKLT[A-Za-z0-9]{12,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' "$STAGE/s3-l4-proxy"; then
  echo "[package][ERR] potential credential found in package" >&2
  exit 1
fi
if grep -En '^(AWS_SECRET_ACCESS_KEY|S3_SECRET_KEY|TOS_SK)=.+' \
  "$STAGE/s3-l4-proxy/config.example.env"; then
  echo "[package][ERR] potential credential found in package" >&2
  exit 1
fi

tar_metadata_args=(--no-xattrs)
if tar --version 2>/dev/null | grep -qi 'bsdtar'; then
  tar_metadata_args+=(--no-mac-metadata)
fi
COPYFILE_DISABLE=1 tar "${tar_metadata_args[@]}" -C "$STAGE" -czf "$OUTPUT" s3-l4-proxy
echo "[package] created $OUTPUT"
tar -tzf "$OUTPUT"
