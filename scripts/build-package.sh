#!/usr/bin/env bash
# Build dist/old-homelab-<version>.zip, after the checks pass. Your homelab.conf and secrets.env are never included.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
scripts/check.sh
version=$(cat VERSION)
name="old-homelab-$version"
mkdir -p dist
rm -f "dist/$name.zip" "dist/$name.zip.sha256"
stage=$(mktemp -d "${TMPDIR:-/tmp}/old-homelab.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/old-homelab"
tar --exclude=./.git --exclude=./dist --exclude=./.claude --exclude=./dry-run-root --exclude=./homelab.conf --exclude=./secrets.env --exclude=.DS_Store -cf - . | tar -xf - -C "$stage/old-homelab"
(cd "$stage" && zip -qr "$OLDPWD/dist/$name.zip" old-homelab)
(cd dist && shasum -a 256 "$name.zip" >"$name.zip.sha256")
echo "built dist/$name.zip"
cat "dist/$name.zip.sha256"
