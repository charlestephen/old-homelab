#!/usr/bin/env bash
# DNS node: two Technitium servers, dnsdist and keepalived, with a certificate from acme.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars TZ DNS_ZONE DNS_NSNET_PARENT DNS_NSNET_SUBNET_V4 DNS_NSNET_GATEWAY_V4 DNS_NSNET_SUBNET_V6 \
    DNS_VIP_V4 DNS_VIP_V6 DNS_BACKENDS DNS_A_NAME DNS_A_IP DNS_A_IP6 DNS_A_MAC DNS_A_NET_IP \
    DNS_B_NAME DNS_B_IP DNS_B_IP6 DNS_B_MAC DNS_B_NET_IP DNSDIST_IP DNSDIST_IP6 DNSDIST_MAC DNSDIST_PEER_IP \
    KEEPALIVED_NODE_NAME KEEPALIVED_PRIORITY KEEPALIVED_VMAC DNSDIST_ADMIN_NETS DNS_CERT_NAME \
    LOGDB_HOST LOGDB_NAME LOGDB_USER TECHNITIUM_VERSION DNSDIST_IMAGE ADMIN_EMAIL \
    CONTAINER_NET_SUBNET CONTAINER_NET_GATEWAY DNS_CONTAINER_MEMORY_MAX DNS_CONTAINER_CPU_QUOTA

# the macvlan parent is a VLAN interface on the host; it has to exist already
if [ "$DRY_RUN" != 1 ] && ! ip link show "$DNS_NSNET_PARENT" >/dev/null 2>&1; then
    die "network interface $DNS_NSNET_PARENT does not exist. Create the VLAN interface first (for example with nmcli)."
fi

# ---- secrets ------------------------------------------------------------------------------------------------
create_secrets dns_admin_password dns_pfx_password dnsdist_web_password dnsdist_console_key logdb_password cf_token cf_account_id
slack_args=()
if [ -n "${SECRET__slack_keepalived_webhook:-}" ]; then
    create_secrets slack_keepalived_webhook
    slack_args=(--secret slack_keepalived_webhook)
fi

# ---- directories --------------------------------------------------------------------------------------------
for d in /srv/dns/console /srv/dns/a /srv/dns/b /srv/acme.sh /srv/dnsdist /srv/keepalived /var/log/dns; do
    make_dir "$d"
done

# ---- networks -----------------------------------------------------------------------------------------------
ensure_network nsnet -d macvlan -o parent="$DNS_NSNET_PARENT" -o no_default_route=true \
    --subnet="$DNS_NSNET_SUBNET_V4" --gateway="$DNS_NSNET_GATEWAY_V4" --subnet="$DNS_NSNET_SUBNET_V6" \
    --route=0.0.0.0/0,"$DNS_NSNET_GATEWAY_V4"
ensure_network dnsnet --subnet="$CONTAINER_NET_SUBNET" --gateway="$CONTAINER_NET_GATEWAY" --dns="$CONTAINER_NET_GATEWAY"

# ---- configuration files ------------------------------------------------------------------------------------
# dnsdist: one backend line per Technitium server, and the admin networks as a Lua list
# the escaped quotes are meant literally: this text is written into the dnsdist configuration
# shellcheck disable=SC2089
DNSDIST_BACKENDS_LUA=""
i=0
for ip in $DNS_BACKENDS; do
    i=$((i + 1))
    DNSDIST_BACKENDS_LUA+="newServer({address=\"$ip:538\", name=\"$(printf '%02d' "$i")\", order=$i, useProxyProtocol=true, healthCheckMode=\"lazy\", lazyHealthCheckFailedInterval=1, lazyHealthCheckThreshold=20, checkName=\"dnsdist-health.internal.\", checkType=\"A\", checkTimeout=900, maxCheckFailures=5, rise=2})"$'\n'
done
DNSDIST_ADMIN_NETS_LUA=""
IFS=, read -r -a nets <<<"$DNSDIST_ADMIN_NETS"
for n in "${nets[@]}"; do DNSDIST_ADMIN_NETS_LUA+="\"${n// /}\", "; done
DNSDIST_ADMIN_NETS_LUA=${DNSDIST_ADMIN_NETS_LUA%, }
DNSDIST_BACKENDS_LUA=${DNSDIST_BACKENDS_LUA%$'\n'}

render "$here/files/dnsdist.conf.tmpl" /srv/dnsdist/dnsdist.conf
render "$here/files/keepalived.conf.tmpl" /srv/keepalived/keepalived.conf
install_file "$here/files/notify.sh" /srv/keepalived/notify.sh 0755

# ---- certificate --------------------------------------------------------------------------------------------
# Issue a wildcard certificate with a Cloudflare DNS challenge. Technitium reads the .pfx; dnsdist reads the PEM
# files from the same directory. The PFX password comes from a Podman secret, never from the command line.
if [ ! -s "$ROOT/srv/acme.sh/${DNS_CERT_NAME}_ecc/fullchain.cer" ]; then
    log "issuing the certificate for $DNS_CERT_NAME"
    run podman run --rm --network dnsnet \
        --secret cf_token,type=env,target=CF_Token \
        --secret cf_account_id,type=env,target=CF_Account_ID \
        --secret dns_pfx_password,type=mount,target=pfx_password \
        -e LE_WORKING_DIR=/acme.sh -e LE_CONFIG_HOME=/acme.sh \
        -v /srv/acme.sh:/acme.sh \
        --entrypoint sh docker.io/neilpang/acme.sh:latest -c \
        "acme.sh --issue --server letsencrypt --dns dns_cf -d '$DNS_CERT_NAME' -d '*.$DNS_CERT_NAME' --keylength ec-256 --to-pkcs12 --password \"\$(cat /run/secrets/pfx_password)\" --dnssleep 30 --certificate-profile classic -m '$ADMIN_EMAIL'"
fi

# the Technitium web console
log "unpacking the Technitium console"
run podman run --rm -v /srv/dns/console:/target ghcr.io/bygarcia/technitium-console:latest

# ---- services -----------------------------------------------------------------------------------------------
technitium() { # container name, host name prefix, data directory, ipv4, ipv6, mac, address on dnsnet
    podlet_unit -d "Technitium DNS Server $2" --after=network-online.target \
        podman run -d=true --replace --name "$1" --hostname "$1" \
        --network="nsnet:ip=$4,ip6=$5,mac=$6" --network="dnsnet:ip=$7" \
        --pull newer --restart always \
        --health-cmd "dig +short +retry=0 +norecurse @localhost cloudflare.com || exit 1" \
        --health-interval 60s --health-timeout 15s --health-retries 3 --health-start-period 45s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret dns_admin_password,type=env,target=DNS_SERVER_ADMIN_PASSWORD \
        --secret dns_pfx_password,type=env,target=DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PASSWORD \
        -e TZ="$TZ" \
        -e DNS_SERVER_DOMAIN="$2.$DNS_ZONE" \
        -e DNS_SERVER_IPV6=true \
        -e DNS_SERVER_WEB_SERVICE_HTTP_PORT=5380 \
        -e DNS_SERVER_WEB_SERVICE_HTTPS_PORT=53443 \
        -e DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS=true \
        -e DNS_SERVER_WEB_SERVICE_USE_SELF_SIGNED_CERT=false \
        -e DNS_SERVER_WEB_SERVICE_TLS_CERTIFICATE_PATH="/certs/$DNS_CERT_NAME.pfx" \
        -e DNS_SERVER_WEB_SERVICE_HTTP_TO_TLS_REDIRECT=true \
        -e DNS_SERVER_OPTIONAL_PROTOCOL_DNS_OVER_HTTP=false \
        -e DNS_SERVER_ENABLE_BLOCKING=true \
        -e DNS_SERVER_ALLOW_TXT_BLOCKING_REPORT=true \
        -e DNS_SERVER_LOG_USING_LOCAL_TIME=true \
        -e DNS_SERVER_LOG_FOLDER_PATH=/var/log/dns \
        -e DNS_SERVER_LOG_MAX_LOG_FILE_DAYS=30 \
        -e DNS_SERVER_STATS_ENABLE_IN_MEMORY_STATS=false \
        -e DNS_SERVER_STATS_MAX_STAT_FILE_DAYS=365 \
        -e DNS_SERVER_WEB_SERVICE_WWW_FOLDER_PATH=/opt/technitium-console \
        -v "/srv/acme.sh/${DNS_CERT_NAME}_ecc:/certs:ro" \
        -v "$3:/etc/dns" \
        -v /var/log/dns:/var/log/dns \
        -v /srv/dns/console:/opt/technitium-console:ro \
        "docker.io/technitium/dns-server:$TECHNITIUM_VERSION"
}

technitium dns-server-a "$DNS_A_NAME" /srv/dns/a "$DNS_A_IP" "$DNS_A_IP6" "$DNS_A_MAC" "$DNS_A_NET_IP"
technitium dns-server-b "$DNS_B_NAME" /srv/dns/b "$DNS_B_IP" "$DNS_B_IP6" "$DNS_B_MAC" "$DNS_B_NET_IP"
resource_limits dns-server-a "$DNS_CONTAINER_MEMORY_MAX" "$DNS_CONTAINER_CPU_QUOTA"
resource_limits dns-server-b "$DNS_CONTAINER_MEMORY_MAX" "$DNS_CONTAINER_CPU_QUOTA"

### dnsdist
# keepalived shares dnsdist's network namespace, so it has to be stopped before dnsdist can be replaced.
# eth0 needs arp_ignore and arp_filter, or it answers ARP for the VIP with its own MAC. The host's resolvers on
# dnsnet cannot be reached from nsnet, so DNS points at the Technitium servers on nsnet.
run podman rm -f --ignore keepalived
dns_args=()
for ip in $DNS_BACKENDS; do dns_args+=(--dns "$ip"); done
podlet_unit -d "DNSDist" --after=network-online.target \
    podman run --replace -d=true --name dnsdist --hostname dnsdist --network nsnet \
    --ip "$DNSDIST_IP" --ip6 "$DNSDIST_IP6" --mac-address "$DNSDIST_MAC" --pull newer --restart always --user root \
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BROADCAST \
    "${dns_args[@]}" \
    --sysctl net.ipv4.conf.all.rp_filter=0 \
    --sysctl net.ipv4.conf.eth0.rp_filter=0 \
    --sysctl net.ipv4.conf.eth0.arp_ignore=1 \
    --sysctl net.ipv4.conf.eth0.arp_filter=1 \
    --sysctl net.ipv6.conf.eth0.accept_ra=2 \
    --sysctl net.ipv6.conf.default.accept_ra=0 \
    --sysctl net.ipv6.conf.default.autoconf=0 \
    --secret dnsdist_web_password --secret dnsdist_console_key \
    -v /srv/dnsdist/dnsdist.conf:/etc/dnsdist/dnsdist.conf:ro \
    -v "/srv/acme.sh/${DNS_CERT_NAME}_ecc:/certs:ro" \
    "$DNSDIST_IMAGE"

### keepalived (shares dnsdist's network namespace)
podlet_unit -d "Keepalived" --after=network-online.target \
    podman run --replace -d=true --name keepalived --network container:dnsdist --requires=dnsdist --pull newer --restart always --user root \
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BROADCAST \
    "${slack_args[@]}" \
    -e KEEPALIVED_VIPS="$DNS_VIP_V4 $DNS_VIP_V6" \
    -v /srv/keepalived/keepalived.conf:/etc/keepalived/keepalived.conf:ro \
    -v /srv/keepalived/notify.sh:/etc/keepalived/notify.sh:ro \
    docker.io/osixia/keepalived:latest

### certificate renewals
podlet_unit -d "acme.sh renewals" --after=network-online.target \
    podman run -d=true --replace --name acme-sh --hostname acme-sh --network dnsnet --restart always --user 0:0 \
    --label "io.containers.autoupdate=registry" \
    --secret cf_token,type=env,target=CF_Token --secret cf_account_id,type=env,target=CF_Account_ID \
    -e TZ="$TZ" -e LE_WORKING_DIR=/acme.sh -e LE_CONFIG_HOME=/acme.sh \
    -v /srv/acme.sh:/acme.sh \
    docker.io/neilpang/acme.sh:latest daemon

### PgBouncer for the DNS query-log database
podlet_unit -d "PgBouncer for DNS" \
    podman run -d=true --replace --name pgbouncer --hostname pgbouncer --net dnsnet --restart always --user root \
    --label "io.containers.autoupdate=registry" \
    --secret logdb_password,type=env,target=DB_PASSWORD \
    -e TZ="$TZ" -e AUTH_TYPE=scram-sha-256 -e DB_USER="$LOGDB_USER" -e DB_HOST="$LOGDB_HOST" -e DB_NAME="$LOGDB_NAME" \
    -e MAX_CLIENT_CONNECTIONS=250 -e POOLMODE=transaction -e SERVER_RESET_QUERY="DISCARD ALL" \
    docker.io/edoburu/pgbouncer:latest

reload_and_start dns-server-a.service dns-server-b.service dnsdist.service keepalived.service acme-sh.service pgbouncer.service
log "dns-node $DNS_NODE finished. Next: join the servers into a Technitium cluster in the web console."
