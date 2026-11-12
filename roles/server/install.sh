#!/usr/bin/env bash
# Server node: Traefik, PostgreSQL, Plex, AI tools and, optionally, the VPN-bound media stack.
# shellcheck disable=SC2154,SC2054 # SECRET__* names are set by load_config; podman options contain commas
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars TZ ADMIN_EMAIL SERVER_SERVICES SERVER_DOMAIN CONTAINER_NET_SUBNET CONTAINER_NET_GATEWAY TRAEFIK_VERSION ACME_RESOLVERS MEDIA_DIR DOWNLOADS_DIR

export SERVICES="$SERVER_SERVICES ${MEDIA_SERVICES:-}"

if [ "${SERVER_STORAGE_PACKAGES:-no}" = yes ]; then
    log "installing ZFS, Samba and NFS"
    apt_install "linux-headers-$(dpkg --print-architecture)" zfs-dkms zfsutils-linux samba samba-common-bin mdadm nfs-kernel-server
fi

ensure_network dnsnet --subnet="$CONTAINER_NET_SUBNET" --gateway="$CONTAINER_NET_GATEWAY" --dns="$CONTAINER_NET_GATEWAY"

started=()
unit() { # description, then a podman run line
    local desc=$1
    shift
    podlet_unit -d "$desc" --after=network-online.target "$@"
}
# app_route NAME PORT: a web interface at NAME.SERVER_DOMAIN
app_route() { route "$1" "$1.$SERVER_DOMAIN" "http://${3:-$1}:$2"; }
# the settings every linuxserver.io style container shares
user_env=(-e PUID=1000 -e PGID=1000 -e TZ="$TZ")

# ---- Traefik --------------------------------------------------------------------------------------------------
if want traefik; then
    create_secrets cf_dns_api_token
    for d in /etc/traefik/dynamic /etc/traefik/acme /etc/traefik/signals /var/log/traefik; do make_dir "$d"; done
    touch "$ROOT/etc/traefik/acme/letsencrypt.json"
    chmod 600 "$ROOT/etc/traefik/acme/letsencrypt.json"
    render "$here/files/traefik.yml.tmpl" /etc/traefik/traefik.yml
    traefik_api_auth
    unit "Traefik Reverse Proxy" \
        podman run -d=true --replace --name traefik --hostname traefik --network dnsnet --pull newer --restart always \
        --security-opt=no-new-privileges \
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

if want traefik-manager-agent; then
    traefik_manager_agent dnsnet && started+=(traefik-manager-agent.service)
fi

# ---- PostgreSQL, pgAdmin, hishtory ------------------------------------------------------------------------------
if want postgresql; then
    require_vars POSTGRES_IMAGE POSTGRES_DATA_DIR SERVER_PG_MEMORY SERVER_PG_CPUS SERVER_PG_MAX_CONNECTIONS
    create_secrets postgres_password
    make_dir "$POSTGRES_DATA_DIR"
    unit "PostgreSQL with TimescaleDB" \
        podman run -d=true --replace --name postgresql --hostname postgresql --network dnsnet --pull newer --restart always --user root \
        --health-cmd "pg_isready -U postgres -d postgres" --health-interval 30s --health-timeout 10s \
        --health-retries 3 --health-start-period 45s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret postgres_password,type=env,target=POSTGRES_PASSWORD \
        -e TZ="$TZ" -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
        -e TS_TUNE_MAX_CONNS="$SERVER_PG_MAX_CONNECTIONS" -e TS_TUNE_MEMORY="$SERVER_PG_MEMORY" -e TS_TUNE_NUM_CPUS="$SERVER_PG_CPUS" \
        -v "$POSTGRES_DATA_DIR:/var/lib/postgresql" \
        "$POSTGRES_IMAGE"
    started+=(postgresql.service)
fi

if want pgadmin; then
    require_vars PGADMIN_HOST PGADMIN_EMAIL
    create_secrets pgadmin_password
    make_dir /srv/pgadmin 0755 5050:5050
    unit "pgAdmin" --after=postgresql.service \
        podman run -d=true --replace --name pgadmin --hostname pgadmin --network dnsnet --pull newer --restart always --user root \
        --label "io.containers.autoupdate=registry" \
        --secret pgadmin_password,type=env,target=PGADMIN_DEFAULT_PASSWORD \
        -e TZ="$TZ" -e PGADMIN_LISTEN_PORT=80 -e PGADMIN_DEFAULT_EMAIL="$PGADMIN_EMAIL" -e PGADMIN_DISABLE_POSTFIX=True \
        -v /srv/pgadmin:/var/lib/pgadmin \
        docker.io/dpage/pgadmin4:latest
    route pgadmin "$PGADMIN_HOST" http://pgadmin:80
    started+=(pgadmin.service)
fi

if want hishtory; then
    create_secrets hishtory_db_password
    plain_secret hishtory_db_password
    # the connection string carries the password, so it is stored as a secret of its own
    export SECRET__hishtory_dsn="postgresql://hishtory:$SECRET__hishtory_db_password@postgresql:5432/hishtory?sslmode=disable"
    create_secrets hishtory_dsn
    make_dir /srv/hishtory
    unit "Hishtory Server" --after=postgresql.service \
        podman run -d=true --replace --name hishtory-server --hostname hishtory-server --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret hishtory_dsn,type=env,target=HISHTORY_POSTGRES_DB \
        "${user_env[@]}" \
        -p 8083:8080 \
        -v /srv/hishtory:/config \
        lscr.io/linuxserver/hishtory-server:latest
    app_route hishtory 8080 hishtory-server
    started+=(hishtory-server.service)
fi

# ---- Plex and friends -------------------------------------------------------------------------------------------
if want plex; then
    require_vars PLEX_HOST MEDIA_DIR
    plex_claim=()
    if [ -n "${SECRET__plex_claim:-}" ]; then
        create_secrets plex_claim
        plex_claim=(--secret plex_claim,type=env,target=PLEX_CLAIM)
    fi
    make_dir /srv/plex
    unit "Plex Media Server" \
        podman run -d=true --replace --name plex --hostname plex --network host --pull newer --restart always \
        --device=/dev/dri:/dev/dri \
        --health-cmd "wget --quiet --spider http://localhost:32400/web" --health-interval 30s --health-timeout 10s \
        --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        "${plex_claim[@]}" \
        "${user_env[@]}" -e VERSION=docker \
        -v /srv/plex:/config \
        -v "$MEDIA_DIR/tv:/tv" -v "$MEDIA_DIR/movies:/movies" -v "$MEDIA_DIR/xxx:/xxx" \
        docker.io/linuxserver/plex:latest
    # Plex uses the host network, so Traefik reaches it through the host
    route plex "$PLEX_HOST" http://host.containers.internal:32400
    started+=(plex.service)
fi

if want tautulli; then
    make_dir /srv/tautulli
    unit "Tautulli" \
        podman run -d=true --replace --name tautulli --hostname tautulli --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        "${user_env[@]}" \
        -v /srv/tautulli:/config \
        -v "/srv/plex/Library/Application Support/Plex Media Server/Logs:/plex_logs:ro" \
        docker.io/linuxserver/tautulli:latest
    app_route tautulli 8181
    started+=(tautulli.service)
fi

# ---- AI tools and a development environment ----------------------------------------------------------------------
if want ollama; then
    make_dir /srv/ollama
    unit "Ollama" \
        podman run -d=true --replace --name ollama --hostname ollama --network dnsnet --pull newer --restart always \
        --device /dev/dri \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /srv/ollama:/root/.ollama \
        docker.io/ollama/ollama:latest
    started+=(ollama.service)
fi

if want open-webui; then
    require_vars AI_HOST OIDC_ISSUER OPEN_WEBUI_OIDC_CLIENT_ID
    create_secrets open_webui_secret_key open_webui_oidc_client_secret open_webui_admin_password
    make_dir /srv/open-webui
    unit "Open WebUI" --after=ollama.service \
        podman run -d=true --replace --name open-webui --hostname open-webui --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret open_webui_secret_key,type=env,target=WEBUI_SECRET_KEY \
        --secret open_webui_oidc_client_secret,type=env,target=OAUTH_CLIENT_SECRET \
        --secret open_webui_admin_password,type=env,target=WEBUI_ADMIN_PASSWORD \
        -e TZ="$TZ" -e ENABLE_PERSISTENT_CONFIG=false -e WEBUI_URL="https://$AI_HOST" \
        -e ENABLE_LOGIN_FORM=True -e ENABLE_PASSWORD_CHANGE_FORM=False -e ENABLE_PASSWORD_AUTH=True \
        -e ENABLE_OAUTH_SIGNUP=True -e DEFAULT_USER_ROLE=pending -e ENABLE_ADMIN_CHAT_ACCESS=False \
        -e ENABLE_OLLAMA_API=True -e OLLAMA_BASE_URL=http://ollama:11434 -e ENABLE_OPENAI_API=False \
        -e ENABLE_API_KEYS=True -e ENABLE_VERSION_UPDATE_CHECK=True \
        -e WEBUI_SESSION_COOKIE_SAME_SITE=strict -e WEBUI_SESSION_COOKIE_SECURE=True \
        -e WEBUI_AUTH_COOKIE_SAME_SITE=strict -e WEBUI_AUTH_COOKIE_SECURE=True \
        -e CORS_ALLOW_ORIGIN="https://$AI_HOST" \
        -e OAUTH_CLIENT_ID="$OPEN_WEBUI_OIDC_CLIENT_ID" -e OPENID_PROVIDER_URL="$OIDC_ISSUER/.well-known/openid-configuration" \
        -e OAUTH_PROVIDER_NAME="Pocket ID" -e OAUTH_SCOPES="openid email profile groups" \
        -e OAUTH_MERGE_ACCOUNTS_BY_EMAIL=False -e OAUTH_CODE_CHALLENGE_METHOD=S256 -e OAUTH_USERNAME_CLAIM=preferred_username \
        -e OPENID_REDIRECT_URI="https://$AI_HOST/oauth/oidc/callback" \
        -e WEBUI_ADMIN_EMAIL="$ADMIN_EMAIL" -e WEBUI_ADMIN_NAME="Administrator" \
        -v /srv/open-webui:/app/backend/data \
        ghcr.io/open-webui/open-webui:main
    route open-webui "$AI_HOST" http://open-webui:8080
    started+=(open-webui.service)
fi

if want code-server; then
    require_vars CODE_HOST
    create_secrets code_server_sudo_password
    make_dir /srv/code-server
    unit "code-server" \
        podman run -d=true --replace --name code-server --hostname code-server --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret code_server_sudo_password,type=env,target=SUDO_PASSWORD \
        "${user_env[@]}" -e PROXY_DOMAIN="$CODE_HOST" -e DEFAULT_WORKSPACE=/config/workspace \
        -v /srv/code-server:/config \
        lscr.io/linuxserver/code-server:latest
    route code-server "$CODE_HOST" http://code-server:8443
    started+=(code-server.service)
fi

if want hawser; then
    require_vars DOCKHAND_URL
    create_secrets dockhand_token
    run systemctl enable --now podman.socket
    unit "Hawser (Dockhand agent)" \
        podman run -d=true --replace --name hawser --hostname hawser --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret dockhand_token,type=env,target=TOKEN \
        -e TZ="$TZ" -e DOCKHAND_SERVER_URL="$DOCKHAND_URL" \
        -v /run/podman/podman.sock:/var/run/docker.sock \
        ghcr.io/finsys/hawser:latest
    started+=(hawser.service)
fi

# ---- media: a torrent client that only works through the VPN -------------------------------------------------------
# qBittorrent and the helpers that share its network use gluetun's network namespace, so they stop when it stops.
if want gluetun; then
    require_vars VPN_PROVIDER VPN_COUNTRIES VPN_DNS
    create_secrets vpn_wireguard_key gluetun_control_password
    plain_secret gluetun_control_password
    export SECRET__gluetun_auth_role="{\"auth\":\"basic\",\"username\":\"admin\",\"password\":\"$SECRET__gluetun_control_password\"}"
    create_secrets gluetun_auth_role
    make_dir /srv/gluetun
    unit "Gluetun VPN" \
        podman run -d=true --replace --name gluetun --hostname gluetun --network dnsnet --pull newer --restart always --user 0 \
        --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun:/dev/net/tun \
        --label "io.containers.autoupdate=registry" \
        --secret vpn_wireguard_key,type=env,target=WIREGUARD_PRIVATE_KEY \
        --secret gluetun_auth_role,type=env,target=HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE \
        -e TZ="$TZ" -e VPN_SERVICE_PROVIDER="$VPN_PROVIDER" -e VPN_TYPE=wireguard -e SERVER_COUNTRIES="$VPN_COUNTRIES" \
        -e PORT_FORWARD_ONLY=on -e VPN_PORT_FORWARDING=on -e VPN_PORT_FORWARDING_PROVIDER="$VPN_PROVIDER" \
        -e DNS_UPSTREAM_RESOLVER_TYPE=plain -e DNS_UPSTREAM_PLAIN_ADDRESSES="$VPN_DNS:53" \
        -e BLOCK_MALICIOUS=on -e BLOCK_SURVEILLANCE=on -e HEALTH_RESTART_VPN=on \
        -e FIREWALL_OUTBOUND_SUBNETS="$CONTAINER_NET_SUBNET,$VPN_DNS/32" \
        -p 127.0.0.1:8081:8081 \
        -v /srv/gluetun:/gluetun \
        docker.io/qmcgaw/gluetun:latest
    started+=(gluetun.service)
fi

if want qbittorrent; then
    make_dir /srv/qbittorrent/torrents
    make_dir "${DOWNLOADS_DIR:?DOWNLOADS_DIR is not set in homelab.conf}"
    create_secrets qbittorrent_password gluetun_control_password
    unit "qBittorrent" --after=gluetun.service --requires=gluetun.service --binds-to=gluetun.service \
        podman run -d=true --replace --name qbittorrent --hostname qbittorrent --network container:gluetun --requires=gluetun --pull newer --restart always --user 1000:1000 \
        --label "io.containers.autoupdate=registry" \
        "${user_env[@]}" -e WEBUI_PORT=8081 \
        -v /srv/qbittorrent:/config -v /srv/qbittorrent/torrents:/torrents \
        -v "$DOWNLOADS_DIR:/downloads/incomplete" -v "$MEDIA_DIR:/downloads/complete" \
        docker.io/linuxserver/qbittorrent:latest
    # keeps qBittorrent's listening port equal to the port the VPN forwards
    unit "Gluetun port forwarding helper" --after=qbittorrent.service --requires=qbittorrent.service --binds-to=gluetun.service \
        podman run -d=true --replace --name gluetun-ports --hostname gluetun-ports --network container:gluetun --requires=gluetun,qbittorrent --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret gluetun_control_password,type=env,target=GLUETUN_PASS \
        --secret qbittorrent_password,type=env,target=QBIT_PASS \
        -e TZ="$TZ" -e GLUETUN_URL=http://gluetun:8000/v1/portforward -e GLUETUN_USER=admin \
        -e QBIT_URL=http://127.0.0.1:8081 -e QBIT_USER=admin -e INTERVAL_SECONDS=60 \
        docker.io/swaya1125/gluetun-port-forwarding-helper:latest
    app_route qbittorrent 8081 gluetun
    started+=(qbittorrent.service gluetun-ports.service)
fi

if want qui; then
    make_dir /srv/qui
    unit "qui" --after=qbittorrent.service \
        podman run -d=true --replace --name qui --hostname qui --network dnsnet --pull newer --restart always --user 1000:1000 \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" -v /srv/qui:/config \
        ghcr.io/autobrr/qui:latest
    app_route qui 7476
    started+=(qui.service)
fi

if want autobrr; then
    make_dir /srv/autobrr
    unit "autobrr" \
        podman run -d=true --replace --name autobrr --hostname autobrr --network dnsnet --pull newer --restart always --user 0 \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" -v /srv/autobrr:/config \
        ghcr.io/autobrr/autobrr:latest
    app_route autobrr 7474
    started+=(autobrr.service)
fi

# ---- the Servarr applications and helpers ---------------------------------------------------------------------------
if want flaresolverr; then
    unit "FlareSolverr" \
        podman run -d=true --replace --name flaresolverr --hostname flaresolverr --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        "${user_env[@]}" \
        ghcr.io/flaresolverr/flaresolverr:latest
    started+=(flaresolverr.service)
fi

# servarr NAME PORT DESCRIPTION [extra podman options...]: one linuxserver.io Servarr application
servarr() {
    local name=$1 port=$2 desc=$3
    shift 3
    make_dir "/srv/$name"
    unit "$desc" \
        podman run -d=true --replace --name "$name" --hostname "$name" --network dnsnet --pull newer --restart always --user 1000:1000 \
        --label "io.containers.autoupdate=registry" \
        "${user_env[@]}" -v "/srv/$name:/config" "$@" \
        "lscr.io/linuxserver/$name:latest"
    app_route "$name" "$port"
    started+=("$name.service")
}
want prowlarr && servarr prowlarr 9696 "Prowlarr"
want radarr && servarr radarr 7878 "Radarr" -v "$MEDIA_DIR/movies:/movies" -v "$DOWNLOADS_DIR/movies:/downloads"
want sonarr && servarr sonarr 8989 "Sonarr" -v "$MEDIA_DIR/tv:/tv" -v "$DOWNLOADS_DIR/tv:/downloads"

if want whisparr; then
    for v in v2 v3; do
        make_dir "/srv/whisparr/$v"
        unit "Whisparr $v" \
            podman run -d=true --replace --name "whisparr$v" --hostname "whisparr$v" --network dnsnet --pull newer --restart always \
            --label "io.containers.autoupdate=registry" \
            "${user_env[@]}" -e UMASK=002 -e WEBUI_PORTS=6969/tcp \
            -v "/srv/whisparr/$v:/config" -v "$DOWNLOADS_DIR/complete/xxx:/downloads" -v "$MEDIA_DIR/xxx:/data" \
            "ghcr.io/hotio/whisparr:$v-develop"
        app_route "whisparr$v" 6969
        started+=("whisparr$v.service")
    done
fi

if want pyload; then
    make_dir /srv/pyload-ng
    unit "pyLoad" \
        podman run -d=true --replace --name pyload-ng --hostname pyload-ng --network dnsnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        "${user_env[@]}" -p 9666:9666 \
        -v /srv/pyload-ng:/config -v "$DOWNLOADS_DIR:/downloads" \
        lscr.io/linuxserver/pyload-ng:latest
    app_route pyload 8000 pyload-ng
    started+=(pyload-ng.service)
fi

if want maintainerr; then
    make_dir /srv/maintainerr 0755 1000:1000
    unit "Maintainerr" \
        podman run -d=true --replace --name maintainerr --hostname maintainerr --network dnsnet --pull newer --restart always --user 1000:1000 \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /srv/maintainerr:/opt/data -v "$MEDIA_DIR:/data/media" \
        ghcr.io/maintainerr/maintainerr:latest
    app_route maintainerr 6246
    started+=(maintainerr.service)
fi

reload_and_start "${started[@]}"

# ---- the hishtory database, created once PostgreSQL answers ----------------------------------------------------------
if want postgresql && want hishtory; then
    plain_secret postgres_password hishtory_db_password
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] psql (stdin): role and database hishtory\n'
    else
        log "waiting for PostgreSQL"
        for _ in $(seq 1 60); do
            podman exec postgresql pg_isready -U postgres >/dev/null 2>&1 && break
            sleep 2
        done
        podman exec -i postgresql psql -U postgres -v ON_ERROR_STOP=1 -q <<SQL
\\set pw '$SECRET__hishtory_db_password'
SELECT 'CREATE ROLE hishtory LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hishtory') \\gexec
ALTER ROLE hishtory PASSWORD :'pw';
SELECT 'CREATE DATABASE hishtory OWNER hishtory' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'hishtory') \\gexec
SQL
    fi
fi

log "server finished: ${started[*]}"
