#!/usr/bin/env bash
# Create secrets.env from secrets.env.example, filling in random values where a value can be generated.
# Secrets that come from somewhere else (Cloudflare, Slack, Forgejo, Tailscale) stay as CHANGE_ME.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

out=secrets.env
[ ! -e "$out" ] || { echo "$out already exists; remove it first if you want a new one" >&2; exit 1; }

# names that must come from an outside service
external=" cf_token cf_account_id cf_dns_api_token runner_registration_token cloudflared_public_token geoip_account_id geoip_license_key geometrikks_carto_key kutt_oidc_client_secret open_webui_oidc_client_secret dockhand_token vpn_wireguard_key smtp_password qbittorrent_password "

umask 077
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *=CHANGE_ME)
            name=${line%%=*}
            case "$external" in
                *" $name "*) printf '%s\n' "$line" ;;
                *) printf '%s=%s\n' "$name" "$(openssl rand -base64 36 | tr -d '\n=+/' | cut -c1-40)" ;;
            esac
            ;;
        *) printf '%s\n' "$line" ;;
    esac
done <secrets.env.example >"$out"

# these two have a required format
sed -i.bak "s|^dnsdist_console_key=.*|dnsdist_console_key=$(openssl rand -base64 32)|" "$out"
sed -i.bak "s|^pocket_id_encryption_key=.*|pocket_id_encryption_key=$(openssl rand -base64 32)|" "$out"
rm -f "$out.bak"

# a Fernet key: 32 random bytes, URL-safe base64 with padding
sed -i.bak "s|^tm_otp_encryption_key=.*|tm_otp_encryption_key=$(openssl rand -base64 32 | tr '+/' '-_')|" "$out"
rm -f "$out.bak"

echo "wrote $out"
echo "still to fill in by hand: $(grep -c '=CHANGE_ME' "$out") value(s):"
grep '=CHANGE_ME' "$out" | cut -d= -f1 | sed 's/^/  /'
