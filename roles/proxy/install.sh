#!/usr/bin/env bash
# Proxy node: public Traefik with CrowdSec and geoblocking, Cloudflare tunnels, identity, links, monitoring.
# shellcheck disable=SC2154,SC2054 # SECRET__* names are set by load_config; podman options contain commas
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib/common.sh
. "$here/../../lib/common.sh"
load_config
require_configured
need_root
require_vars TZ ADMIN_EMAIL PROXY_SERVICES PROXY_DOMAIN CONTAINER_NET_SUBNET CONTAINER_NET_GATEWAY DATA_DIR \
    TRAEFIK_VERSION ACME_RESOLVERS PROXY_ALLOWED_COUNTRIES PROXY_TRUSTED_NETS

export SERVICES=$PROXY_SERVICES

ensure_network pubnet --subnet="$CONTAINER_NET_SUBNET" --gateway="$CONTAINER_NET_GATEWAY" --dns="$CONTAINER_NET_GATEWAY"

started=()
# every container is started once its own unit exists; these ones only run on the public network
unit() { # description, then a podman run line: a Quadlet unit that starts after the network is up
    local desc=$1
    shift
    podlet_unit -d "$desc" --after=network-online.target "$@"
}

# ---- Traefik, with CrowdSec and geoblocking in front of every public route ------------------------------------
if want traefik; then
    create_secrets cf_dns_api_token crowdsec_bouncer_key
    for d in /etc/traefik/dynamic /etc/traefik/acme /etc/traefik/signals /var/log/traefik; do make_dir "$d"; done
    touch "$ROOT/etc/traefik/acme/letsencrypt.json" "$ROOT/var/log/traefik/access.log"
    chmod 600 "$ROOT/etc/traefik/acme/letsencrypt.json"
    render "$here/files/traefik.yml.tmpl" /etc/traefik/traefik.yml
    traefik_api_auth

    # shellcheck disable=SC2086 # the country list is meant to split into words
    GEO_COUNTRIES_YAML=$(yaml_list 12 $PROXY_ALLOWED_COUNTRIES)
    mapfile -t nets < <(split_list "$PROXY_TRUSTED_NETS")
    GEO_ALLOWED_IPS_YAML=$(yaml_list 12 "${nets[@]}" "$CONTAINER_NET_SUBNET")
    export GEO_COUNTRIES_YAML GEO_ALLOWED_IPS_YAML
    render "$here/files/middlewares.yml.tmpl" /etc/traefik/dynamic/middlewares.yml

    unit "Traefik Reverse Proxy" \
        podman run -d=true --replace --name traefik --hostname traefik --network pubnet --pull newer --restart always \
        --health-cmd "$TRAEFIK_HEALTH" --health-interval 30s --health-timeout 10s --health-retries 3 \
        --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret cf_dns_api_token,type=env,target=CF_DNS_API_TOKEN \
        --secret traefik_basic_auth,type=mount,target=traefik_basic_auth \
        --secret crowdsec_bouncer_key,type=mount,target=crowdsec_bouncer_key \
        -e TZ="$TZ" \
        -p 80:80 -p 443:443 -p 443:443/udp \
        -v /etc/traefik:/etc/traefik \
        -v /etc/traefik/signals:/signals \
        -v /var/log/traefik:/var/log/traefik \
        "docker.io/traefik:$TRAEFIK_VERSION"
    started+=(traefik.service)
fi

if want traefik-manager-agent; then
    # CrowdSec's bouncer key lets the manager show the decisions CrowdSec has made
    if want crowdsec; then
        traefik_manager_agent pubnet --secret crowdsec_bouncer_key,type=env,target=CROWDSEC_API_KEY -e CROWDSEC_LAPI_URL=http://crowdsec:8080 \
            && started+=(traefik-manager-agent.service)
    else
        traefik_manager_agent pubnet && started+=(traefik-manager-agent.service)
    fi
fi

# ---- CrowdSec: reads the Traefik access log, and Traefik asks it which addresses to block ---------------------
if want crowdsec; then
    create_secrets crowdsec_bouncer_key
    make_dir /srv/crowdsec/config
    make_dir /srv/crowdsec/data
    make_dir /srv/crowdsec/config/acquis.d
    install_file "$here/files/acquis-traefik.yaml" /srv/crowdsec/config/acquis.d/traefik.yaml
    unit "CrowdSec" \
        podman run -d=true --replace --name crowdsec --hostname crowdsec --network pubnet --pull newer --restart always --user 0:0 \
        --label "io.containers.autoupdate=registry" \
        --secret crowdsec_bouncer_key,type=env,target=BOUNCER_KEY_traefik \
        -e TZ="$TZ" -e COLLECTIONS="crowdsecurity/traefik crowdsecurity/linux" \
        -v /srv/crowdsec/config:/etc/crowdsec \
        -v /srv/crowdsec/data:/var/lib/crowdsec/data \
        -v /var/log/traefik:/var/log/traefik:ro \
        docker.io/crowdsecurity/crowdsec:latest
    resource_limits crowdsec 1G 100%
    started+=(crowdsec.service)
fi

# ---- error pages ----------------------------------------------------------------------------------------------
if want error-pages; then
    unit "Error Pages" \
        podman run -d=true --replace --name error-pages --hostname error-pages --network pubnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" -e SEND_SAME_HTTP_CODE=false -e SHOW_DETAILS=true -e LOG_LEVEL=info -e TEMPLATE_NAME=connection \
        ghcr.io/tarampampam/error-pages:latest serve
    started+=(error-pages.service)
fi

# ---- MaxMind GeoIP database updates ---------------------------------------------------------------------------
if want geoip; then
    create_secrets geoip_account_id geoip_license_key
    make_dir /srv/geoipupdate
    unit "MaxMind GeoIP Updater" \
        podman run -d=true --replace --name geoipupdate --hostname geoipupdate --network pubnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret geoip_account_id,type=env,target=GEOIPUPDATE_ACCOUNT_ID \
        --secret geoip_license_key,type=env,target=GEOIPUPDATE_LICENSE_KEY \
        -e TZ="$TZ" -e GEOIPUPDATE_EDITION_IDS="GeoLite2-City GeoLite2-ASN GeoLite2-Country" -e GEOIPUPDATE_FREQUENCY=72 \
        -v /srv/geoipupdate:/usr/share/GeoIP \
        ghcr.io/maxmind/geoipupdate:latest
    started+=(geoipupdate.service)
fi

# ---- Cloudflare tunnels: every name gets CLOUDFLARED_REPLICAS containers ------------------------------------------
if want cloudflared; then
    require_vars CLOUDFLARED_TUNNELS CLOUDFLARED_REPLICAS
    for tunnel in $CLOUDFLARED_TUNNELS; do
        create_secrets "cloudflared_${tunnel}_token"
        for i in $(seq 0 $((CLOUDFLARED_REPLICAS - 1))); do
            cname="cloudflared-$tunnel$i"
            unit "Cloudflare tunnel $tunnel $i" \
                podman run -d=true --replace --name "$cname" --hostname "$cname" --network pubnet --pull newer --restart always \
                --label "io.containers.autoupdate=registry" \
                --secret "cloudflared_${tunnel}_token,type=env,target=TUNNEL_TOKEN" \
                -e TZ="$TZ" \
                docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate --loglevel info --metrics 127.0.0.1:2000 --protocol quic run
            started+=("$cname.service")
        done
    done
fi

# ---- PostgreSQL, PgBouncer and the databases the services need --------------------------------------------------
if want postgresql; then
    require_vars POSTGRES_IMAGE POSTGRES_DATA_DIR
    create_secrets postgres_password
    make_dir "$POSTGRES_DATA_DIR"
    unit "PostgreSQL" \
        podman run -d=true --replace --name postgresql --hostname postgresql --network pubnet --pull newer --restart always --user root \
        --health-cmd "pg_isready -U postgres -d postgres" --health-interval 30s --health-timeout 10s \
        --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret postgres_password,type=env,target=POSTGRES_PASSWORD \
        -e TZ="$TZ" -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
        -v "$POSTGRES_DATA_DIR:/var/lib/postgresql" \
        "$POSTGRES_IMAGE"
    started+=(postgresql.service)
fi

if want pgbouncer; then
    create_secrets pgbouncer_auth_password
    plain_secret pgbouncer_auth_password
    export SECRET__pgbouncer_userlist="\"pgbouncer_auth\" \"$SECRET__pgbouncer_auth_password\""
    create_secrets pgbouncer_userlist
    make_dir /srv/pgbouncer
    render "$here/files/pgbouncer.ini.tmpl" /srv/pgbouncer/pgbouncer.ini
    unit "PgBouncer" \
        podman run -d=true --replace --name pgbouncer --hostname pgbouncer --network pubnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret pgbouncer_userlist,type=mount,target=pgbouncer_userlist \
        -e TZ="$TZ" \
        -v /srv/pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro \
        docker.io/edoburu/pgbouncer:latest
    started+=(pgbouncer.service)
fi

# ---- identity: Pocket ID and authentik -------------------------------------------------------------------------
if want pocket-id; then
    require_vars PROXY_ID_HOST
    create_secrets pocket_id_encryption_key
    make_dir /srv/pocket-id
    unit "Pocket ID" \
        podman run -d=true --replace --name pocket-id --hostname pocket-id --network pubnet --pull newer --restart always \
        --health-cmd "/app/pocket-id healthcheck" --health-interval 60s --health-timeout 10s --health-retries 3 \
        --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret pocket_id_encryption_key,type=env,target=ENCRYPTION_KEY \
        -e TZ="$TZ" -e APP_URL="https://$PROXY_ID_HOST" -e TRUST_PROXY=true \
        -v /srv/pocket-id:/app/data \
        ghcr.io/pocket-id/pocket-id:latest
    route pocket-id "$PROXY_ID_HOST" http://pocket-id:1411 secure
    started+=(pocket-id.service)
fi

if want authentik; then
    require_vars PROXY_AUTHENTIK_HOST AUTHENTIK_VERSION SMTP_HOST SMTP_PORT SMTP_USER SMTP_FROM
    create_secrets authentik_db_password authentik_secret_key smtp_password
    make_dir /srv/authentik/data
    make_dir /srv/authentik/templates
    # authentik keeps its own database connection to PostgreSQL: it uses LISTEN/NOTIFY, which transaction pooling breaks
    authentik_env=(
        --secret authentik_db_password,type=env,target=AUTHENTIK_POSTGRESQL__PASSWORD
        --secret authentik_secret_key,type=env,target=AUTHENTIK_SECRET_KEY
        --secret smtp_password,type=env,target=AUTHENTIK_EMAIL__PASSWORD
        -e TZ="$TZ"
        -e AUTHENTIK_POSTGRESQL__HOST=postgresql -e AUTHENTIK_POSTGRESQL__NAME=authentik -e AUTHENTIK_POSTGRESQL__USER=authentik
        -e AUTHENTIK_ERROR_REPORTING__ENABLED=false
        -e AUTHENTIK_EMAIL__HOST="$SMTP_HOST" -e AUTHENTIK_EMAIL__PORT="$SMTP_PORT" -e AUTHENTIK_EMAIL__USERNAME="$SMTP_USER"
        -e AUTHENTIK_EMAIL__FROM="$SMTP_FROM" -e AUTHENTIK_EMAIL__USE_TLS=true -e AUTHENTIK_EMAIL__USE_SSL=false
        -e AUTHENTIK_EMAIL__TIMEOUT=30
        -e AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS="$CONTAINER_NET_SUBNET"
    )
    unit "authentik Server" \
        podman run -d=true --replace --name authentik --hostname authentik --network pubnet --pull newer --restart always --shm-size=512m \
        --label "io.containers.autoupdate=registry" \
        "${authentik_env[@]}" \
        -v /srv/authentik/data:/data -v /srv/authentik/templates:/templates \
        "ghcr.io/goauthentik/server:$AUTHENTIK_VERSION" server
    unit "authentik Worker" \
        podman run -d=true --replace --name authentik-worker --hostname authentik-worker --network pubnet --pull newer --restart always --user root --shm-size=512m \
        --label "io.containers.autoupdate=registry" \
        "${authentik_env[@]}" \
        -v /run/podman/podman.sock:/var/run/docker.sock \
        -v /srv/authentik/data:/data -v /srv/authentik/templates:/templates \
        "ghcr.io/goauthentik/server:$AUTHENTIK_VERSION" worker
    route authentik "$PROXY_AUTHENTIK_HOST" http://authentik:9000 secure
    started+=(authentik.service authentik-worker.service)
fi

# ---- small services ---------------------------------------------------------------------------------------------
if want uptime-kuma; then
    require_vars PROXY_UPTIME_HOST
    make_dir /srv/uptime-kuma
    unit "Uptime Kuma" \
        podman run -d=true --replace --name uptime-kuma --hostname uptime-kuma --network pubnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /srv/uptime-kuma:/app/data \
        docker.io/louislam/uptime-kuma:2
    route uptime-kuma "$PROXY_UPTIME_HOST" http://uptime-kuma:3001 secure
    started+=(uptime-kuma.service)
fi

if want headscale; then
    require_vars PROXY_HEADSCALE_HOST HEADSCALE_VERSION HEADSCALE_BASE_DOMAIN HEADSCALE_PREFIX_V4 HEADSCALE_PREFIX_V6 HEADSCALE_DNS
    make_dir /etc/headscale
    make_dir /srv/headscale
    render "$here/files/headscale.yaml.tmpl" /etc/headscale/config.yaml
    unit "Headscale" \
        podman run -d=true --replace --name headscale --hostname headscale --network pubnet --pull newer --restart always \
        --read-only --tmpfs /var/run/headscale \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /etc/headscale:/etc/headscale:ro \
        -v /srv/headscale:/var/lib/headscale \
        "docker.io/headscale/headscale:$HEADSCALE_VERSION" serve
    # tailnet clients are not limited by country, so this route skips the security chain
    route headscale "$PROXY_HEADSCALE_HOST" http://headscale:8080
    started+=(headscale.service)
fi

if want kutt; then
    require_vars PROXY_KUTT_HOST PROXY_ID_HOST SMTP_HOST SMTP_PORT SMTP_USER SMTP_FROM KUTT_OIDC_CLIENT_ID
    create_secrets kutt_jwt_secret kutt_oidc_client_secret smtp_password
    make_dir /srv/kutt 0755 1000:1000
    unit "Kutt Link Shortener" \
        podman run -d=true --replace --name kutt --hostname kutt --network pubnet --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret kutt_jwt_secret,type=env,target=JWT_SECRET \
        --secret smtp_password,type=env,target=MAIL_PASSWORD \
        --secret kutt_oidc_client_secret,type=env,target=OIDC_CLIENT_SECRET \
        -e TZ="$TZ" -e DB_FILENAME=/srv/kutt/data.sqlite -e DEFAULT_DOMAIN="$PROXY_KUTT_HOST" \
        -e TRUST_PROXY=true -e CUSTOM_DOMAIN_USE_HTTPS=true \
        -e MAIL_ENABLED=true -e MAIL_HOST="$SMTP_HOST" -e MAIL_PORT="$SMTP_PORT" -e MAIL_USER="$SMTP_USER" \
        -e MAIL_FROM="$SMTP_FROM" -e MAIL_SECURE=false -e CONTACT_EMAIL="$ADMIN_EMAIL" \
        -e OIDC_ENABLED=true -e OIDC_ISSUER="https://$PROXY_ID_HOST" -e OIDC_CLIENT_ID="$KUTT_OIDC_CLIENT_ID" \
        -e OIDC_PROMPT=login -e OIDC_SCOPE="openid profile email groups" -e OIDC_EMAIL_CLAIM=email \
        -e OIDC_BUTTON_TEXT="Log in with Pocket ID" \
        -v /srv/kutt:/srv/kutt \
        docker.io/kutt/kutt:latest
    route kutt "$PROXY_KUTT_HOST" http://kutt:3000 secure
    started+=(kutt.service)
fi

if want geometrikks; then
    require_vars PROXY_GEO_HOST
    create_secrets geometrikks_db_password geometrikks_admin_password geometrikks_carto_key geoip_account_id geoip_license_key
    make_dir /srv/geoipupdate
    unit "GeoMetrikks Visualizer for Traefik" --after=traefik.service \
        podman run -d=true --replace --name geometrikks --hostname geometrikks --network pubnet --pull newer --restart always \
        --health-cmd "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8000/health/ready', timeout=5).read()\" || exit 1" \
        --health-interval 30s --health-timeout 10s --health-retries 3 --health-start-period 15s --health-on-failure=restart \
        --label "io.containers.autoupdate=registry" \
        --secret geometrikks_admin_password,type=env,target=APP_ADMIN_PASSWORD \
        --secret geometrikks_db_password,type=env,target=DB_PASSWORD \
        --secret geometrikks_carto_key,type=env,target=MAP_CARTO_API_KEY \
        --secret geoip_account_id,type=env,target=MAXMINDDB_USER_ID \
        --secret geoip_license_key,type=env,target=MAXMINDDB_LICENSE_KEY \
        -e TZ="$TZ" -e APP_ADMIN_USER=admin -e APP_SESSION_SECURE=true -e APP_TRUSTED_PROXIES="$CONTAINER_NET_SUBNET" \
        -e ACCESS_LOG_DIR=/var/log/traefik -e LOGPARSER_LOG_PATHS=/var/log/traefik/access.log \
        -e DB_USER=geometrikks -e DB_HOST=pgbouncer -e DB_PORT=5432 -e DB_DATABASE=geometrikks \
        -v /srv/geoipupdate:/app/data/geoip \
        -v /var/log/traefik:/var/log/traefik:ro \
        ghcr.io/gilbn/geometrikks:latest
    route geometrikks "$PROXY_GEO_HOST" http://geometrikks:8000 secure
    started+=(geometrikks.service)
fi

# ---- monitoring -------------------------------------------------------------------------------------------------
if want node-exporter; then
    require_vars NODE_EXPORTER_LISTEN
    unit "Prometheus Node Exporter" \
        podman run -d=true --replace --name node-exporter --hostname node-exporter --net=host --pid=host --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /:/host:ro,rslave \
        quay.io/prometheus/node-exporter:latest --path.rootfs=/host --web.listen-address="$NODE_EXPORTER_LISTEN"
    started+=(node-exporter.service)
fi

if want alloy; then
    require_vars LOKI_URL
    make_dir /srv/alloy
    render "$here/files/config.alloy.tmpl" /srv/alloy/config.alloy
    unit "Grafana Alloy" \
        podman run -d=true --replace --name alloy --hostname alloy --network pubnet --pull newer --restart always --user root \
        --label "io.containers.autoupdate=registry" \
        -e TZ="$TZ" \
        -v /srv/alloy/config.alloy:/etc/alloy/config.alloy:ro \
        -v /var/log/journal:/var/log/journal:ro \
        -v /etc/machine-id:/etc/machine-id:ro \
        docker.io/grafana/alloy:latest run --server.http.listen-addr=127.0.0.1:12345 /etc/alloy/config.alloy
    started+=(alloy.service)
fi

reload_and_start "${started[@]}"

# ---- databases: created once PostgreSQL answers, and again harmlessly on a re-run --------------------------------
# The passwords go to psql on its standard input, so they never appear in a process listing.
if want postgresql && want pgbouncer; then
    create_secrets authentik_db_password geometrikks_db_password
    plain_secret postgres_password authentik_db_password geometrikks_db_password
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] psql (stdin): roles pgbouncer_auth, authentik, geometrikks; databases authentik, geometrikks; function pgbouncer.user_lookup\n'
    else
        log "waiting for PostgreSQL"
        for _ in $(seq 1 60); do
            podman exec postgresql pg_isready -U postgres >/dev/null 2>&1 && break
            sleep 2
        done
        podman exec -i postgresql psql -U postgres -v ON_ERROR_STOP=1 -q <<SQL
\\set pw_auth '$SECRET__pgbouncer_auth_password'
\\set pw_authentik '$SECRET__authentik_db_password'
\\set pw_geo '$SECRET__geometrikks_db_password'
SELECT 'CREATE ROLE pgbouncer_auth LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_auth') \\gexec
SELECT 'CREATE ROLE authentik LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authentik') \\gexec
SELECT 'CREATE ROLE geometrikks LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'geometrikks') \\gexec
ALTER ROLE pgbouncer_auth PASSWORD :'pw_auth';
ALTER ROLE authentik PASSWORD :'pw_authentik';
ALTER ROLE geometrikks PASSWORD :'pw_geo';
SELECT 'CREATE DATABASE authentik OWNER authentik' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'authentik') \\gexec
SELECT 'CREATE DATABASE geometrikks OWNER geometrikks' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'geometrikks') \\gexec
CREATE SCHEMA IF NOT EXISTS pgbouncer;
CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(IN i_username text, OUT uname text, OUT phash text)
RETURNS record AS \$\$
BEGIN
    SELECT rolname::text, CASE WHEN rolvaliduntil < now() THEN NULL ELSE rolpassword END
    FROM pg_authid
    WHERE rolname = i_username AND rolcanlogin AND rolname IN ('authentik', 'geometrikks')
    INTO uname, phash;
    RETURN;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;
REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;
SQL
    fi
fi

log "proxy finished: ${started[*]}"
