#!/usr/bin/env bash
# Core services: Traefik, PostgreSQL with TimescaleDB, Forgejo, Pocket ID, Loki, Alloy, Grafana.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars TZ ADMIN_EMAIL CORE_SERVICES CORE_DOMAIN CONTAINER_NET_SUBNET CONTAINER_NET_GATEWAY DATA_DIR \
    TRAEFIK_VERSION ACME_RESOLVERS

export SERVICES=$CORE_SERVICES

ensure_network dnsnet --subnet="$CONTAINER_NET_SUBNET" --gateway="$CONTAINER_NET_GATEWAY" --dns="$CONTAINER_NET_GATEWAY"

started=()

# ---- Traefik ------------------------------------------------------------------------------------------------
if want traefik; then
    create_secrets cf_dns_api_token
    for d in /etc/traefik/dynamic /etc/traefik/acme /etc/traefik/signals /var/log/traefik; do make_dir "$d"; done
    touch "$ROOT/etc/traefik/acme/letsencrypt.json"
    chmod 600 "$ROOT/etc/traefik/acme/letsencrypt.json"
    render "$here/files/traefik.yml.tmpl" /etc/traefik/traefik.yml
    traefik_api_auth

    podlet_unit -d "Traefik Reverse Proxy" --after=network-online.target \
        podman run -d=true --replace --name traefik --hostname traefik --network dnsnet --pull newer --restart always \
        --health-cmd "$TRAEFIK_HEALTH" --health-interval 30s --health-timeout 10s --health-retries 3 \
        --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret cf_dns_api_token,type=env,target=CF_DNS_API_TOKEN \
        --secret traefik_basic_auth,type=mount,target=traefik_basic_auth \
        -e TZ="$TZ" \
        -p 80:80 -p 443:443 -p 443:443/udp \
        -v /etc/traefik:/etc/traefik \
        -v /etc/traefik/signals:/signals \
        -v /var/log/traefik:/var/log/traefik \
        "docker.io/traefik:$TRAEFIK_VERSION"
    started+=(traefik.service)
fi

# ---- Traefik Manager: the main instance, which also manages the Traefik agents on the other hosts ---------------
if want traefik-manager; then
    require_vars TM_HOST TRAEFIK_ADMIN_USER
    create_secrets tm_secret_key tm_otp_encryption_key traefik_admin_password
    make_dir /srv/traefik-manager
    make_dir /srv/traefik-manager/backups
    podlet_unit -d "Traefik Manager" --after=traefik.service --requires=traefik.service \
        podman run -d=true --replace --name traefik-manager --hostname traefik-manager --network dnsnet --pull newer --restart always \
        --health-cmd "curl -fsS -o /dev/null http://127.0.0.1:5000/api/health" --health-interval 60s --health-timeout 10s \
        --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret tm_secret_key,type=env,target=SECRET_KEY \
        --secret tm_otp_encryption_key,type=env,target=OTP_ENCRYPTION_KEY \
        --secret traefik_admin_password,type=env,target=TRAEFIK_API_PASSWORD \
        -e TZ="$TZ" -e COOKIE_SECURE=true -e DOMAINS="$CORE_DOMAIN" -e CERT_RESOLVER=letsencrypt \
        -e TRAEFIK_API_URL=http://traefik:8080 -e TRAEFIK_API_USER="$TRAEFIK_ADMIN_USER" \
        -e STATIC_CONFIG_PATH=/etc/traefik/traefik.yml -e CONFIG_DIR=/etc/traefik/dynamic \
        -e ACME_JSON_PATH=/etc/traefik/acme/letsencrypt.json -e ACCESS_LOG_PATH=/var/log/traefik/access.log \
        -e RESTART_METHOD=poison-pill -e SIGNAL_FILE_PATH=/signals/restart.sig \
        -v /srv/traefik-manager:/app/config \
        -v /srv/traefik-manager/backups:/app/backups \
        -v /etc/traefik:/etc/traefik \
        -v /etc/traefik/signals:/signals \
        -v /var/log/traefik:/var/log/traefik:ro \
        ghcr.io/chr0nzz/traefik-manager:latest
    route traefik-manager "$TM_HOST" http://traefik-manager:5000
    started+=(traefik-manager.service)
fi

# ---- PostgreSQL with TimescaleDB --------------------------------------------------------------------------------
if want postgresql; then
    require_vars POSTGRES_IMAGE POSTGRES_DATA_DIR POSTGRES_PUBLISH_ADDRESS
    create_secrets postgres_password
    make_dir "$POSTGRES_DATA_DIR"
    podlet_unit -d "PostgreSQL with TimescaleDB" --after=network-online.target \
        podman run -d=true --replace --name postgresql --hostname postgresql --network dnsnet --pull newer --restart always --user root \
        --health-cmd "pg_isready -U postgres -d postgres" --health-interval 30s --health-timeout 10s \
        --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret postgres_password,type=env,target=POSTGRES_PASSWORD \
        -e TZ="$TZ" -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
        -p "$POSTGRES_PUBLISH_ADDRESS:5432:5432" \
        -v "$POSTGRES_DATA_DIR:/var/lib/postgresql" \
        "$POSTGRES_IMAGE"
    started+=(postgresql.service)
fi

# ---- Forgejo ------------------------------------------------------------------------------------------------
if want forgejo; then
    require_vars FORGEJO_HOST FORGEJO_VERSION FORGEJO_SSH_HOST_PORT FORGEJO_GIT_DIR FORGEJO_LFS_DIR
    make_dir "$DATA_DIR/forgejo"
    make_dir "$FORGEJO_GIT_DIR"
    make_dir "$FORGEJO_LFS_DIR"
    make_dir /var/log/forgejo
    podlet_unit -d "Forgejo Git Server" --after=traefik.service --requires=traefik.service \
        podman run -d=true --replace --name forgejo --hostname forgejo --network dnsnet --pull newer --restart always \
        --cap-add CAP_NET_BIND_SERVICE \
        --health-cmd "wget --spider http://localhost:3000" --health-interval 30s --health-timeout 10s \
        --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -e FORGEJO____APP_NAME=Forgejo \
        -e FORGEJO__database__DB_TYPE=sqlite3 \
        -e FORGEJO__database__PATH=/data/forgejo.db \
        -e FORGEJO__SQLITE_JOURNALMODE=wal \
        -e FORGEJO__server__DOMAIN="$FORGEJO_HOST" \
        -e FORGEJO__server__ROOT_URL="https://$FORGEJO_HOST/" \
        -p "$FORGEJO_SSH_HOST_PORT:2222" \
        -v "$DATA_DIR/forgejo:/data" \
        -v "$FORGEJO_GIT_DIR:/data/git" \
        -v "$FORGEJO_LFS_DIR:/data/lfs" \
        -v /var/log/forgejo:/var/log/forgejo \
        "codeberg.org/forgejo/forgejo:$FORGEJO_VERSION"
    route forgejo "$FORGEJO_HOST" http://forgejo:3000
    started+=(forgejo.service)

    # optional: a Tailscale sidecar that puts Forgejo on the tailnet
    if [ -n "${SECRET__forgejo_tailscale_authkey:-}" ]; then
        create_secrets forgejo_tailscale_authkey
        make_dir "$DATA_DIR/tailscale/forgejo"
        podlet_unit -d "Tailscale for Forgejo" --after=forgejo.service --requires=forgejo.service --binds-to=forgejo.service \
            podman run -d=true --replace --name forgejo-tailscaled --hostname forgejo-tailscale --network dnsnet --pull newer --restart always \
            --label "io.containers.autoupdate=registry" \
            --secret forgejo_tailscale_authkey,type=env,target=TS_AUTHKEY \
            -e TZ="$TZ" -e TS_HOSTNAME=git -e TS_STATE_DIR=/var/lib/tailscale -e TS_USERSPACE=true -e TS_AUTH_ONCE=true \
            -v "$DATA_DIR/tailscale/forgejo:/var/lib/tailscale" \
            docker.io/tailscale/tailscale:stable
        started+=(forgejo-tailscaled.service)
    fi
fi

# ---- Pocket ID ----------------------------------------------------------------------------------------------
if want pocket-id; then
    require_vars POCKET_ID_HOST
    create_secrets pocket_id_encryption_key
    make_dir "$DATA_DIR/pocket-id"
    podlet_unit -d "Pocket ID Authentication Server" --after=traefik.service --requires=traefik.service \
        podman run -d=true --replace --name pocket-id --hostname pocket-id --network dnsnet --pull newer --restart always \
        --health-cmd "/app/pocket-id healthcheck" --health-interval 60s --health-timeout 10s --health-retries 3 \
        --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret pocket_id_encryption_key,type=env,target=ENCRYPTION_KEY \
        -e TZ="$TZ" -e APP_URL="https://$POCKET_ID_HOST" -e TRUST_PROXY=true \
        -v "$DATA_DIR/pocket-id:/app/data" \
        ghcr.io/pocket-id/pocket-id:latest
    route pocket-id "$POCKET_ID_HOST" http://pocket-id:1411
    started+=(pocket-id.service)
fi

# ---- Loki, Alloy, Grafana -----------------------------------------------------------------------------------
if want loki; then
    make_dir "$DATA_DIR/loki"
    render "$here/files/loki-config.yml.tmpl" "$DATA_DIR/loki/loki-config.yml"
    podlet_unit -d "Loki Log Storage" --after=network-online.target \
        podman run -d=true --replace --name loki --hostname loki --network dnsnet --pull newer --restart always --user root \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v "$DATA_DIR/loki:/loki" \
        docker.io/grafana/loki:latest -config.file=/loki/loki-config.yml
    started+=(loki.service)
fi

if want alloy; then
    make_dir "$DATA_DIR/alloy"
    install_file "$here/files/config.alloy" "$DATA_DIR/alloy/config.alloy"
    podlet_unit -d "Grafana Alloy" --after=network-online.target \
        podman run -d=true --replace --name alloy --hostname alloy --network dnsnet --pull newer --restart always --user root \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v "$DATA_DIR/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
        -v /var/log/journal:/var/log/journal:ro \
        -v /etc/machine-id:/etc/machine-id:ro \
        docker.io/grafana/alloy:latest run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy
    started+=(alloy.service)
fi

if want grafana; then
    require_vars GRAFANA_HOST
    create_secrets grafana_admin_password
    make_dir "$DATA_DIR/grafana" 0755 472:472
    podlet_unit -d "Grafana" --after=traefik.service --requires=traefik.service \
        podman run -d=true --replace --name grafana --hostname grafana --network dnsnet --pull newer --restart always --user root \
        --label "io.containers.autoupdate=registry" \
        --secret grafana_admin_password,type=env,target=GF_SECURITY_ADMIN_PASSWORD \
        -e TZ="$TZ" -e GF_SERVER_ROOT_URL="https://$GRAFANA_HOST" \
        -v "$DATA_DIR/grafana:/var/lib/grafana" \
        docker.io/grafana/grafana:latest
    route grafana "$GRAFANA_HOST" http://grafana:3000
    started+=(grafana.service)
fi

reload_and_start "${started[@]}"
log "core finished: ${started[*]}"
