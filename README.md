# old-homelab

One-shot scripts that rebuild a small home lab from a clean Debian install: Podman containers started by systemd, a
highly available DNS pair, a Git server and its supporting services. It is packaged as a single zip file, so a machine
can be rebuilt without any other infrastructure being up.

The scripts are simple on purpose. Each service is one `podlet` command that turns a `podman run` line into a systemd
unit. Values live in one config file and secrets in another, so nothing in a script has to be edited.

## Quick start

```sh
unzip old-homelab-0.1.0.zip && cd old-homelab

cp homelab.conf.example homelab.conf     # addresses, names, versions: edit every value
scripts/gen-secrets.sh                   # creates secrets.env with random values; fill in the few it cannot generate

sudo ./install.sh base                   # Podman, podlet, SSH, firewall, updates
sudo ./install.sh core                   # or dns-node, or forgejo-runner
```

Read what a role would do before it does it:

```sh
./install.sh core --dry-run              # writes into ./dry-run-root and runs no commands
```

`./install.sh --list` shows the roles.

## Roles

| Role | What it installs |
|---|---|
| `base` | Podman and podlet, Cockpit, SSH hardening, firewalld, automatic security updates. Run it first on every host. |
| `dns-node` | Two Technitium DNS servers on a macvlan network, dnsdist (DoT, DoH, DoQ), keepalived with a floating IPv4 and IPv6 address, acme.sh for the certificate, and PgBouncer for query logging. Run it on two hosts to get a highly available pair. |
| `core` | The services listed in `CORE_SERVICES`: Traefik, Traefik Manager (the main instance), PostgreSQL with TimescaleDB, Forgejo, Pocket ID, Loki, Alloy and Grafana. |
| `proxy` | The public edge host. Traefik with a security chain (headers, geoblock, CrowdSec), CrowdSec reading the access log, Cloudflare tunnels, PostgreSQL behind PgBouncer, Pocket ID, authentik, Uptime Kuma, Headscale, Kutt, GeoMetrikks, node-exporter and Alloy. Services are listed in `PROXY_SERVICES`. |
| `server` | The internal application host. Traefik, PostgreSQL, pgAdmin, hishtory, Plex, Tautulli, Ollama, Open WebUI, code-server and the Dockhand agent (`SERVER_SERVICES`), plus an optional VPN-bound media stack: Gluetun, qBittorrent, qui, autobrr and the Servarr apps (`MEDIA_SERVICES`). |
| `forgejo-runner` | A Forgejo Actions runner, installed from the signed release and registered with your server. |

## Configuration

- `homelab.conf` holds values: domain names, addresses, versions. Start from `homelab.conf.example`, which uses
  documentation addresses (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32) and `example.net`.
  The installer refuses to run while `DOMAIN` is still `example.net`.
- `secrets.env` holds secrets. Each name becomes a Podman secret that the container reads, so no value appears in a unit
  file or on a command line. `scripts/gen-secrets.sh` generates what it can. Keep the file out of version control.

Both files are parsed, not executed, and neither is ever included in the zip.

## Safety checks built in

- The installer stops if the example values are still in place.
- `base` refuses to turn off SSH password login unless the admin user already has an authorized key, validates the
  SSH configuration before reloading it, and opens the SSH port in the firewall before the firewall is switched on.
- `dns-node` stops if the VLAN interface the DNS network needs does not exist.
- Every secret is checked before anything is started, and the scripts can be run again: networks, secrets and units
  are replaced, not duplicated.

## Traefik, its login and Traefik Manager

- The Traefik API and dashboard need a username and password on every host (`TRAEFIK_ADMIN_USER` and the
  `traefik_admin_password` secret). They are served only on port 8080 inside the container network, which is never
  published. Traefik reads a bcrypt hash from a Podman secret, and `/ping`, used by the health check, is the only open path.
- Traefik Manager runs on the `core` host (`traefik-manager` in `CORE_SERVICES`, served at `TM_HOST`). Its first
  password is printed once in its log (`podman logs traefik-manager`) and it asks for a new one at the first login.
- To manage the Traefik on the `proxy` and `server` hosts, those hosts run an agent. Register each host in Traefik Manager
  under Settings > Agents, using `http://<TMA_PUBLISH_ADDRESS>:8090` as the URL. Copy the key it shows once into that host's
  `secrets.env` as `tma_api_key`, then run the role again. The agent is skipped while the key is empty.
- Traefik Manager restarts Traefik without any Docker socket: it drops a signal file that Traefik's health check
  notices, and systemd starts Traefik again with the new configuration.

## Adding a service

Copy a block from `roles/core/install.sh`. A service is one `podlet_unit` call with a normal `podman run` line:

```bash
podlet_unit -d "My Service" --after=traefik.service --requires=traefik.service \
    podman run -d --replace --name myservice --hostname myservice --network dnsnet --pull newer --restart always \
    --label "io.containers.autoupdate=registry" \
    --secret myservice_password,type=env,target=APP_PASSWORD \
    -e TZ="$TZ" \
    -v "$DATA_DIR/myservice:/data" \
    docker.io/example/myservice:1.2.3
```

Add the secret name to `secrets.env.example`, any new setting to `homelab.conf.example`, and a `route` line if Traefik
should serve it.

## Packaging

```sh
scripts/build-package.sh                 # checks, then writes dist/old-homelab-<version>.zip and its sha256
```

`scripts/check.sh` runs first and the build stops if it fails. It checks that every script parses, that every template
variable is defined, and that nothing in the tree looks like a real address, name, email address, token or password.
