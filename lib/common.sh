#!/usr/bin/env bash
# Shared helpers, sourced by install.sh and the role scripts.
#
# Environment switches (mostly for testing):
#   ROOT=/some/dir   write every file under this directory instead of /
#   DRY_RUN=1        write files, but run no commands (no apt, podman or systemctl)

PKG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=${ROOT:-}
DRY_RUN=${DRY_RUN:-0}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run a command, or only print it in a dry run
run() {
    if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

need_root() {
    if [ "$DRY_RUN" = 1 ] || [ "$(id -u)" -eq 0 ]; then return 0; fi
    die "run this as root, for example: sudo ./install.sh <role>"
}

# Read KEY=VALUE lines from a file into the environment. The file is parsed, not executed, so it cannot run
# commands. Blank lines and lines starting with # are ignored; one pair of surrounding quotes is removed.
# The optional second argument is a prefix added to every variable name.
load_env_file() {
    local file=$1 prefix=${2:-} line key value
    [ -r "$file" ] || die "cannot read $file"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        key=${key//[[:space:]]/}
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$file: not a KEY=VALUE line: $line"
        case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        export "${prefix}${key}=${value}"
    done <"$file"
}

# Load homelab.conf (values) and, when present, secrets.env (secrets, loaded as SECRET__<name>).
load_config() {
    load_env_file "${HOMELAB_CONF:-$PKG_DIR/homelab.conf}"
    if [ -r "${HOMELAB_SECRETS:-$PKG_DIR/secrets.env}" ]; then
        load_env_file "${HOMELAB_SECRETS:-$PKG_DIR/secrets.env}" SECRET__
    fi
}

# Refuse to run on the example values: they are documentation addresses and example.net, and would configure
# a host with settings that cannot work.
require_configured() {
    [ "${ALLOW_EXAMPLE:-0}" = 1 ] && return 0
    [ "${DOMAIN:-example.net}" != example.net ] || die "homelab.conf still has DOMAIN=example.net. Edit it first."
}

# require_vars NAME...: stop with a clear message when a setting is missing
require_vars() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "$v is not set in homelab.conf"
        [ "${!v}" != CHANGE_ME ] || die "$v is still CHANGE_ME in homelab.conf"
    done
}

# render TEMPLATE DESTINATION [MODE]: copy a template, replacing every @@NAME@@ with the value of NAME
render() {
    local src=$1 dst=$2 mode=${3:-0644} out name
    [ -r "$src" ] || die "missing template $src"
    out=$(cat "$src")
    for name in $(grep -o '@@[A-Z0-9_]*@@' "$src" | sort -u | tr -d '@'); do
        [ -n "${!name+x}" ] || die "$src needs $name, which is not set in homelab.conf"
        out=${out//"@@$name@@"/"${!name}"}
    done
    mkdir -p "$(dirname "$ROOT$dst")"
    printf '%s\n' "$out" >"$ROOT$dst"
    chmod "$mode" "$ROOT$dst"
}

# install_file SOURCE DESTINATION [MODE]: copy a file unchanged
install_file() {
    local src=$1 dst=$2 mode=${3:-0644}
    [ -r "$src" ] || die "missing file $src"
    mkdir -p "$(dirname "$ROOT$dst")"
    cp "$src" "$ROOT$dst"
    chmod "$mode" "$ROOT$dst"
}

# Every service is made the way the old scripts made it: one podlet command that turns a "podman run" line into a
# Quadlet unit systemd starts at boot. podlet_unit passes its arguments to podlet with the usual options:
#
#   podlet_unit -d "Description" --after=network-online.target \
#       podman run -d --replace --name web --network dnsnet --secret db_password,type=env,target=DB_PASSWORD image
#
# In a dry run the command is printed instead, and, if podlet is installed, the unit it would write goes to
# $ROOT/quadlet-preview/<container name>.container.
podlet_unit() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] podlet -i -u --overwrite -s Environment %s\n' "$*"
        if command -v podlet >/dev/null 2>&1; then
            local name="" arg prev=""
            for arg in "$@"; do
                [ "$prev" = --name ] && name=$arg
                prev=$arg
            done
            mkdir -p "$ROOT/quadlet-preview"
            podlet -s Environment "$@" >"$ROOT/quadlet-preview/${name:-unit}.container"
        fi
        return 0
    fi
    command -v podlet >/dev/null 2>&1 || die "podlet is not installed (run ./install.sh base first)"
    podlet -i -u --overwrite -s Environment "$@"
}

# resource_limits UNIT MEMORY_MAX CPU_QUOTA: limit a service through systemd, which works on every Podman version
# (the Memory= key that podlet writes for --memory needs a newer Podman than Debian stable ships)
resource_limits() {
    local dir="$ROOT/etc/systemd/system/$1.service.d"
    mkdir -p "$dir"
    printf '[Service]\nMemoryMax=%s\nCPUQuota=%s\n' "$2" "$3" >"$dir/limits.conf"
}

# ensure_network NAME [podman network create options...]: create a Podman network unless it already exists
ensure_network() {
    local name=$1
    shift
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] podman network create %s %s\n' "$*" "$name"
    elif podman network exists "$name"; then
        log "network $name already exists"
    else
        podman network create "$@" "$name"
    fi
}

# podlet release used by every role; the checksums are for the release assets
PODLET_VERSION=v0.3.2
PODLET_SHA256_AARCH64=ff9f25b72c4871b0507fe1e6f31c8ef6836dcaf5151bb0d424f81a79832ce2e1
PODLET_SHA256_X86_64=d28975df717ce20374a6dc4176670ce6faf8dcb3ab4af761a39fdd2f863d03f6

# install podlet from the GitHub release, checking its sha256 first
install_podlet() {
    local asset want tmp
    if command -v podlet >/dev/null 2>&1 && podlet --version 2>/dev/null | grep -q "${PODLET_VERSION#v}"; then
        log "podlet ${PODLET_VERSION} is already installed"
        return 0
    fi
    case "$(uname -m)" in
        aarch64 | arm64) asset=podlet-aarch64-unknown-linux-gnu.tar.xz; want=$PODLET_SHA256_AARCH64 ;;
        x86_64 | amd64) asset=podlet-x86_64-unknown-linux-gnu.tar.xz; want=$PODLET_SHA256_X86_64 ;;
        *) die "no podlet build for $(uname -m)" ;;
    esac
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] download %s and check sha256 %s\n' "$asset" "$want"
        return 0
    fi
    tmp=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$asset" \
        "https://github.com/containers/podlet/releases/download/${PODLET_VERSION}/${asset}"
    echo "$want  $tmp/$asset" | sha256sum -c - >/dev/null || die "podlet download does not match its checksum"
    tar -xJf "$tmp/$asset" -C "$tmp"
    install -m 0755 "$(find "$tmp" -type f -name podlet | head -1)" /usr/local/bin/podlet
    rm -rf "$tmp"
    log "installed $(podlet --version)"
}

apt_install() {
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# create_secrets NAME...: create a Podman secret for each name from secrets.env
create_secrets() {
    local name var value
    for name in "$@"; do
        var="SECRET__$name"
        value=${!var:-}
        case "$value" in
            ''|CHANGE_ME*) die "secret '$name' is empty in secrets.env (run scripts/gen-secrets.sh, or fill it in)" ;;
        esac
        if [ "$DRY_RUN" = 1 ]; then
            printf '[dry-run] podman secret create --replace %s -\n' "$name"
        else
            printf '%s' "$value" | podman secret create --replace "$name" - >/dev/null
        fi
    done
}

# start the units Quadlet generates from the files just written
reload_and_start() {
    run systemctl daemon-reload
    local unit
    for unit in "$@"; do
        run systemctl start "$unit"
    done
}

# route NAME HOST URL [secure]: tell Traefik to send HOST to URL. "secure" puts the SecurityChain middleware in front.
route() {
    local tmpl="$PKG_DIR/lib/route.yml.tmpl"
    [ "${4:-}" = secure ] && tmpl="$PKG_DIR/lib/route-secure.yml.tmpl"
    ROUTE_NAME=$1 ROUTE_HOST=$2 ROUTE_URL=$3
    export ROUTE_NAME ROUTE_HOST ROUTE_URL
    render "$tmpl" "/etc/traefik/dynamic/$1.yml"
}

# want NAME: is NAME in the space-separated list SERVICES?
want() { [[ " $SERVICES " == *" $1 "* ]]; }

# make a directory (and set its owner when one is given)
make_dir() {
    local dir=$1 mode=${2:-0755} owner=${3:-}
    mkdir -p "$ROOT$dir"
    chmod "$mode" "$ROOT$dir"
    if [ -n "$owner" ] && [ "$DRY_RUN" != 1 ]; then chown "$owner" "$ROOT$dir"; fi
}

# yaml_list INDENT ITEM...: print each item as a YAML list entry indented by INDENT spaces
yaml_list() {
    local pad=$1 item
    shift
    for item in "$@"; do printf '%*s- "%s"\n' "$pad" "" "$item"; done
}

# split_list STRING: print the items of a comma or space separated list, one per line
split_list() { printf '%s\n' "$1" | tr ', ' '\n\n' | grep -v '^$' || true; }

# plain_secret NAME...: refuse values that would break the SQL and config files they are written into
plain_secret() {
    local n v
    for n in "$@"; do
        v=SECRET__$n
        case "${!v:-}" in
            *[\'\"\\\ ]*) die "secret '$n' contains a quote, backslash or space; use letters, digits and punctuation only" ;;
        esac
    done
}

# Traefik health check. Traefik Manager restarts Traefik by creating /signals/restart.sig; this check notices the file,
# removes it and stops Traefik, and systemd starts it again with the new static configuration.
export TRAEFIK_HEALTH='[ ! -f /signals/restart.sig ] || { rm -f /signals/restart.sig; kill -TERM 1; }; traefik healthcheck --ping'

# traefik_api_auth: put the Traefik API and dashboard behind basic auth. The password comes from the traefik_admin_password
# secret; Traefik reads a bcrypt hash of it from the traefik_basic_auth secret, never the password itself.
traefik_api_auth() {
    require_vars TRAEFIK_ADMIN_USER
    create_secrets traefik_admin_password
    plain_secret traefik_admin_password
    local hash
    if [ "$DRY_RUN" = 1 ]; then
        hash="$TRAEFIK_ADMIN_USER:dry-run-hash"
    else
        command -v htpasswd >/dev/null 2>&1 || die "htpasswd is not installed (run ./install.sh base first, or: apt install apache2-utils)"
        # shellcheck disable=SC2154 # SECRET__* names are set by load_config
        hash=$(printf '%s' "$SECRET__traefik_admin_password" | htpasswd -niB "$TRAEFIK_ADMIN_USER")
    fi
    export SECRET__traefik_basic_auth="$hash"
    create_secrets traefik_basic_auth
    render "$PKG_DIR/lib/traefik-api.yml.tmpl" /etc/traefik/dynamic/traefik-api.yml
}

# traefik_manager_agent NETWORK [extra podman options]: the agent that lets the Traefik Manager on the core host manage
# this host's Traefik. The API key is created in Traefik Manager (Settings > Agents), so the unit is skipped until
# tma_api_key is filled in. Returns 1 when skipped.
traefik_manager_agent() {
    local net=$1
    shift
    require_vars TMA_PUBLISH_ADDRESS TRAEFIK_ADMIN_USER TZ
    if [ -z "${SECRET__tma_api_key:-}" ]; then
        warn "tma_api_key is empty in secrets.env, so the Traefik Manager agent is skipped. Register this host in Traefik Manager, put the key in secrets.env and run this role again."
        return 1
    fi
    create_secrets tma_api_key traefik_admin_password
    make_dir /srv/traefik-manager-agent/backups
    podlet_unit -d "Traefik Manager Agent" --after=traefik.service --requires=traefik.service \
        podman run -d=true --replace --name traefik-manager-agent --hostname traefik-manager-agent --network "$net" --pull newer --restart always \
        --label "io.containers.autoupdate=registry" \
        --secret tma_api_key,type=env,target=TMA_API_KEY \
        --secret traefik_admin_password,type=env,target=TRAEFIK_API_PASSWORD \
        -e TZ="$TZ" -e TRAEFIK_API_URL=http://traefik:8080 -e TRAEFIK_API_USER="$TRAEFIK_ADMIN_USER" \
        -e CONFIG_PATH=/etc/traefik/dynamic -e STATIC_CONFIG_PATH=/etc/traefik/traefik.yml \
        -e ACME_JSON_PATH=/etc/traefik/acme/letsencrypt.json -e ACCESS_LOG_PATH=/var/log/traefik/access.log \
        -e RESTART_METHOD=poison-pill -e SIGNAL_FILE_PATH=/signals/restart.sig -e BACKUP_DIR=/app/backups \
        "$@" \
        -p "$TMA_PUBLISH_ADDRESS:8090:8090" \
        -v /etc/traefik:/etc/traefik \
        -v /etc/traefik/signals:/signals \
        -v /var/log/traefik:/var/log/traefik:ro \
        -v /srv/traefik-manager-agent/backups:/app/backups \
        ghcr.io/chr0nzz/traefik-manager-agent:latest
}
