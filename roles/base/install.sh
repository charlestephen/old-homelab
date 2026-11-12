#!/usr/bin/env bash
# Base setup for any host: Podman and podlet, SSH, firewall, automatic updates.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars ADMIN_USER SSH_PORT FIREWALL_TRUSTED_SOURCES

# ---- packages ---------------------------------------------------------------------------------------------
# Optional: take Podman and its libraries from the next Debian release. Everything else stays on this one.
if [ "${USE_FORKY_PODMAN:-no}" = yes ]; then
    log "adding the next Debian release for Podman only"
    install_file "$here/files/forky.sources" /etc/apt/sources.list.d/forky.sources
    install_file "$here/files/podman-forky.pref" /etc/apt/preferences.d/90_podman.pref
fi

log "installing packages"
apt_install podman skopeo catatonit passt aardvark-dns netavark uidmap dbus-user-session \
    curl ca-certificates jq unzip xz-utils git gnupg dnsutils iproute2 chrony \
    apache2-utils firewalld cockpit cockpit-podman cockpit-networkmanager unattended-upgrades etckeeper

install_podlet

# containers labelled io.containers.autoupdate=registry are updated by this timer
run systemctl enable --now podman-auto-update.timer

# ---- administrator ----------------------------------------------------------------------------------------
if id "$ADMIN_USER" >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ]; then
    run usermod -aG sudo "$ADMIN_USER"
else
    warn "user $ADMIN_USER does not exist; skipping sudo membership"
fi

# ---- SSH ----------------------------------------------------------------------------------------------------
# Password logins are turned off, so make sure a key is installed first or this would lock you out.
keys="/home/$ADMIN_USER/.ssh/authorized_keys"
if [ "$DRY_RUN" != 1 ] && [ ! -s "$keys" ]; then
    die "$keys is missing or empty. Add your public key before running this (otherwise SSH password login would be turned off with no way in)."
fi
render "$here/files/sshd-hardened.conf.tmpl" /etc/ssh/sshd_config.d/90-homelab.conf
if [ "$DRY_RUN" != 1 ]; then
    if sshd -t; then
        log "SSH configuration is valid; reloading sshd (port $SSH_PORT)"
        systemctl reload ssh
    else
        rm -f /etc/ssh/sshd_config.d/90-homelab.conf
        die "the SSH configuration did not validate; the new file was removed"
    fi
fi

# ---- firewall -----------------------------------------------------------------------------------------------
# Rules go in first and the daemon is started afterwards, so the SSH port is open from the moment it is on.
fw() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] firewall: %s\n' "$*"
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent "$@" >/dev/null
    else
        firewall-offline-cmd "$@" >/dev/null
    fi
}
log "configuring the firewall"
fw --zone=public --add-port="$SSH_PORT/tcp"
fw --zone=public --add-service=cockpit
IFS=, read -r -a sources <<<"$FIREWALL_TRUSTED_SOURCES"
for src in "${sources[@]}"; do
    [ -n "$src" ] && fw --zone=trusted --add-source="$src"
done
IFS=, read -r -a services <<<"${FIREWALL_PUBLIC_SERVICES:-}"
for svc in "${services[@]}"; do
    [ -n "$svc" ] && fw --zone=public --add-service="$svc"
done
run systemctl enable --now firewalld
run firewall-cmd --reload

# ---- automatic security updates -----------------------------------------------------------------------------
install_file "$here/files/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades

log "base setup finished"
