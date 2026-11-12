#!/usr/bin/env bash
# Forgejo Actions runner, installed from the signed release and registered with your Forgejo server.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars FORGEJO_URL RUNNER_NAME RUNNER_LABELS

# the release signing key published by the Forgejo project
RUNNER_SIGNING_KEY=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 # gitleaks:allow (public key fingerprint)

apt_install curl jq gnupg podman nodejs

case "$(uname -m)" in
    aarch64 | arm64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac

# RUNNER_VERSION can be set in homelab.conf (for example 6.4.0); otherwise the latest release is used
version=${RUNNER_VERSION:-}
if [ -z "$version" ] && [ "$DRY_RUN" != 1 ]; then
    version=$(curl -fsSL https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest | jq -r .name | sed 's/^v//')
fi
[ -n "$version" ] || version=0.0.0
url="https://code.forgejo.org/forgejo/runner/releases/download/v${version}/forgejo-runner-${version}-linux-${arch}"

if [ "$DRY_RUN" != 1 ]; then
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/forgejo-runner" "$url"
    curl -fsSL -o "$tmp/forgejo-runner.asc" "$url.asc"
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$RUNNER_SIGNING_KEY"
    gpg --batch --verify "$tmp/forgejo-runner.asc" "$tmp/forgejo-runner" || die "the runner download does not match its signature"
    install -m 0755 "$tmp/forgejo-runner" /usr/local/bin/forgejo-runner
    rm -rf "$tmp"
    log "installed $(forgejo-runner --version)"
else
    printf '[dry-run] download and verify %s\n' "$url"
fi

if ! id runner >/dev/null 2>&1; then run useradd --create-home --shell /bin/bash runner; fi
run loginctl enable-linger runner
run systemctl --user -M runner@ enable --now podman.socket

# register once; the token comes from secrets.env and is only used here
if [ "$DRY_RUN" != 1 ] && [ ! -e /home/runner/.runner ]; then
    token=${SECRET__runner_registration_token:-}
    case "$token" in '' | CHANGE_ME*) die "runner_registration_token is not set in secrets.env" ;; esac
    sudo -u runner -H sh -c 'cd /home/runner && forgejo-runner register --no-interactive --instance "$1" --token "$2" --name "$3" --labels "$4"' \
        _ "$FORGEJO_URL" "$token" "$RUNNER_NAME" "$RUNNER_LABELS"
fi

RUNNER_UID=$(id -u runner 2>/dev/null || echo 1000)
export RUNNER_UID
render "$here/forgejo-runner.service.tmpl" /etc/systemd/system/forgejo-runner.service
run systemctl daemon-reload
run systemctl enable --now forgejo-runner.service
log "forgejo-runner finished"
