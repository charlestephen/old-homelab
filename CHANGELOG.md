# Changelog

## 0.1.0

First release.

### Installer

- `install.sh <role>` runs one role on a host. `--dry-run` writes every file under `./dry-run-root` and runs no commands. `--list` shows the roles.
- Values live in `homelab.conf` and secrets in `secrets.env`. Both are parsed, not executed, and are never included in the zip. The installer refuses to run while `DOMAIN` is still `example.net`.
- Secrets become Podman secrets and are passed to containers as environment variables or mounted files, so no value appears in a unit file or on a command line.
- Every service is created with `podlet -i -u --overwrite -s Environment ... podman run -d=true ...`, which writes a Quadlet unit that systemd starts at boot. Container limits use a systemd drop-in, because `podlet` writes a `Memory=` key that Podman 5.4 rejects.
- `scripts/gen-secrets.sh` creates `secrets.env` with random values. `scripts/check.sh` checks syntax, shellcheck, template variables and that nothing looks like a real address, name, email, token or password. `scripts/build-package.sh` runs the check and builds `dist/old-homelab-<version>.zip` with a sha256 file.

### Roles

- `base`: Podman and `podlet` (pinned release, sha256 checked), Cockpit, SSH hardening (refuses to disable passwords without an authorized key, validates before reloading), firewalld rules applied before the firewall is switched on, automatic security updates, optional Podman from the next Debian release.
- `dns-node`: two Technitium servers on a macvlan network, dnsdist (DoT, DoH, DoQ), keepalived with a floating IPv4 and IPv6 address, acme.sh certificate issuance and renewal over a Cloudflare DNS challenge, PgBouncer for query logging. Covers both Raspberry Pi DNS nodes when run on each with its own values.
- `core`: Traefik, Traefik Manager (main instance), PostgreSQL with TimescaleDB, Forgejo, Pocket ID, Loki, Alloy and Grafana.
- `proxy`: public Traefik with a security chain (headers, geoblock, CrowdSec), CrowdSec reading the Traefik access log, Cloudflare tunnels, PostgreSQL behind PgBouncer, Pocket ID, authentik, Uptime Kuma, Headscale, Kutt, GeoMetrikks, node-exporter, Alloy and the Traefik Manager agent. The database roles and the PgBouncer lookup function are created idempotently over `psql` standard input.
- `server`: Traefik, PostgreSQL, pgAdmin, hishtory, Plex, Tautulli, Ollama, Open WebUI, code-server, the Dockhand agent and the Traefik Manager agent, plus an optional media stack (Gluetun, qBittorrent and its port-forward helper, qui, autobrr, FlareSolverr, Prowlarr, Radarr, Sonarr, Whisparr, pyLoad, Maintainerr).
- `forgejo-runner`: a Forgejo Actions runner installed from the signed release and registered with your server.

### Traefik

- The Traefik API and dashboard require a username and password on every host. They are served only on the internal `traefik` entry point, which is not published, and Traefik reads a bcrypt hash from a Podman secret. `/ping` stays open for the health check.
- Traefik Manager restarts Traefik with the poison-pill method: it writes a signal file, and Traefik's health check removes it and stops Traefik so systemd starts it again. No container socket is mounted.
- Traefik Manager's health check uses `/api/health` on `127.0.0.1`. The `localhost` name and `/healthz` path used by older instructions do not work with the current image.

### Notes

- The proxy does not install Redis, which authentik no longer needs. authentik connects to PostgreSQL directly, because it relies on LISTEN/NOTIFY, which transaction pooling breaks.
- PgBouncer uses `auth_dbname=postgres` so its password lookup runs in the database that holds the lookup function.
- Several images use `:latest`. Pin them once you have tested a combination.
- Not covered: Home Assistant hosts, the UniFi log tools, Traefik Manager's log dashboard agent, CrowdSec Manager, Headplane, host-level CrowdSec bouncer, Tailscale and Webmin on the hosts, Raspberry Pi hardware settings.
- Tested with dry runs, Quadlet generation, config validators and live containers for Traefik, CrowdSec, Headscale, PostgreSQL, PgBouncer, Traefik Manager and its agent. Not yet tested on real hosts: the `base` role's apt, SSH and firewalld changes, certificate issuance, keepalived failover, the media stack and agent registration through the Traefik Manager interface.
