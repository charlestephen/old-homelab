#!/usr/bin/env bash
# Checks the package before it is built or shared: syntax, template variables, and anything that looks like a
# real address, name or secret. Exits non-zero if something needs attention.
#
# Extra, private checks: set SCRUB_DENYLIST to a file of exact strings (one per line) that must never appear.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
bad() { echo "  FAIL  $*"; fail=1; }
ok() { echo "  ok    $*"; }

files() { find . -type f -not -path './.git/*' -not -path './dist/*' -not -path './.claude/*' -not -path './dry-run-root/*' -not -name .DS_Store -not -name 'homelab.conf' -not -name 'secrets.env' | sort; }
# the license, funding file and gitleaks rules name the author or the domains to catch on purpose, so the content scans skip them
# the content scans skip this file, because it has to contain the patterns it looks for
scan() { files | grep -vE '^./scripts/check.sh$|^./LICENSE$|^./.github/FUNDING.yml$|^./.gitleaks.toml$'; }
scripts() { files | grep -E '\.sh$|/install\.sh$|^\./install\.sh$'; }

echo "shell syntax"
n=0
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then n=$((n + 1)); else bad "$f does not parse"; fi
done < <(scripts)
ok "$n scripts parse"

if command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck"
    mapfile -t script_list < <(scripts)
    if shellcheck -x -S warning "${script_list[@]}" >/dev/null 2>&1; then ok "no warnings"; else bad "shellcheck reports problems:"; shellcheck -x -S warning "${script_list[@]}" | head -30; fi
fi

echo "template variables"
defined=$(grep -E '^[A-Z][A-Z0-9_]*=' homelab.conf.example | cut -d= -f1)
set_in_scripts=$(grep -rhoE '^\s*(export )?[A-Z][A-Z0-9_]*=|\b[A-Z][A-Z0-9_]*[+]?=\$|ROUTE_[A-Z]+|RUNNER_UID' roles lib | sed -E 's/^[[:space:]]*(export )?//; s/[+]?=.*//; s/=\$//' | sort -u)
missing=0
for name in $(grep -rhoE '@@[A-Z0-9_]+@@' roles lib | tr -d '@' | sort -u); do
    if ! { echo "$defined" | grep -qx "$name" || echo "$set_in_scripts" | grep -qx "$name"; }; then
        bad "@@$name@@ is used in a template but set nowhere"; missing=1
    fi
done
[ "$missing" = 0 ] && ok "every @@NAME@@ is defined"

echo "addresses"
# allowed: documentation ranges, loopback, wildcard, the public resolvers named in the example config
allowed='^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|127\.|0\.0\.0\.0$|1\.1\.1\.2$|1\.0\.0\.2$)'
hits=$(scan | xargs grep -HnoE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' 2>/dev/null | grep -vE ':(\.[0-9]|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(8|10|12|16))' | awk -F: '{print $0}' | while IFS=: read -r file line ip; do
    # CIDR private-range tokens are generic, not addresses of a real network
    echo "$ip" | grep -qE "$allowed" || echo "$file:$line $ip"
done | grep -vE '10\.0\.0\.0|100\.64\.0\.0|172\.16\.0\.0|192\.168\.0\.0|169\.254\.0\.0')
if [ -n "$hits" ]; then bad "addresses outside the documentation ranges:"; echo "$hits" | head -20 | sed 's/^/        /'; else ok "only documentation addresses"; fi
v6=$(scan | xargs grep -HnoiE '\b(fd[0-9a-f]{2}:[0-9a-f:]+|fe80::[0-9a-f][0-9a-f:]*|2[0-9a-f]{3}:[0-9a-f:]+)' 2>/dev/null | grep -viE '2001:db8|fd7a:115c:a1e0' | head)  # fd7a:115c:a1e0::/48 is Tailscale's published default prefix
if [ -n "$v6" ]; then bad "IPv6 addresses outside 2001:db8::/32:"; echo "$v6" | sed 's/^/        /'; else ok "only documentation IPv6 addresses"; fi

echo "email addresses and names"
mail=$(scan | xargs grep -HnoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null | grep -vE '@example\.(net|com|org)\b')
if [ -n "$mail" ]; then bad "email addresses other than @example.*:"; echo "$mail" | sed 's/^/        /'; else ok "only example addresses"; fi
names=$(scan | xargs grep -HniE 'cst\.nyc|cst\.wtf|handyhomo|brooklynhelpdesk|bkhd|charlestephen|thompson' 2>/dev/null)
if [ -n "$names" ]; then bad "personal or private names:"; echo "$names" | sed 's/^/        /'; else ok "no personal names or domains"; fi

echo "secrets"
keys=$(scan | xargs grep -HnE 'BEGIN [A-Z ]*PRIVATE KEY|tskey-|cfut_|cfat_|ghp_|xox[bp]-' 2>/dev/null)
if [ -n "$keys" ]; then bad "token or key material:"; echo "$keys" | sed 's/^/        /'; else ok "no key or token patterns"; fi
# long random-looking strings: 24 or more letters and digits that include upper case, lower case and a digit
rand=$(scan | xargs grep -HnoE '\b[A-Za-z0-9]{24,}\b' 2>/dev/null | awk -F: '{v=$NF} v ~ /[A-Z]/ && v ~ /[a-z]/ && v ~ /[0-9]/ {print $1 ":" $2 ": " v}')
if [ -n "$rand" ]; then bad "long random-looking strings:"; echo "$rand" | head -15 | sed 's/^/        /'; else ok "no long random strings"; fi
assign=$(scan | xargs grep -HnE '(PASSWORD|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY)[A-Z_]*["'"'"']?[=:] *["'"'"']?[A-Za-z0-9+/_.-]{8,}' 2>/dev/null | grep -vE 'CHANGE_ME|\$|@@|SECRET__|_FILE=|^[^:]*:[0-9]+:\s*#')
if [ -n "$assign" ]; then bad "hard-coded secret assignments:"; echo "$assign" | sed 's/^/        /'; else ok "no hard-coded secret assignments"; fi

if [ -n "${SCRUB_DENYLIST:-}" ] && [ -r "$SCRUB_DENYLIST" ]; then
    echo "private denylist"
    found=$(scan | xargs grep -HnF -f "$SCRUB_DENYLIST" 2>/dev/null)
    if [ -n "$found" ]; then bad "denylisted strings found:"; echo "$found" | cut -d: -f1,2 | sed 's/^/        /'; else ok "none of the $(wc -l <"$SCRUB_DENYLIST" | tr -d ' ') denylisted strings appear"; fi
fi

echo
if [ "$fail" = 0 ]; then echo "all checks passed"; else echo "checks failed"; fi
exit $fail
