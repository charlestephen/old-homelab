#!/usr/bin/env bash
# One-shot installer for a host role.
#
#   sudo ./install.sh <role> [--dry-run]
#   ./install.sh --list
#
# A dry run writes the files into ./dry-run-root and runs no commands, so you can read what would be installed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
. lib/common.sh

usage() {
    cat <<EOF
usage: sudo ./install.sh <role> [--dry-run]
       ./install.sh --list

Roles:
EOF
    list_roles
}

list_roles() {
    local dir name desc
    for dir in roles/*/; do
        name=$(basename "$dir")
        desc=$(sed -n '2s/^# //p' "roles/$name/install.sh" 2>/dev/null)
        printf '  %-16s %s\n' "$name" "$desc"
    done
}

role=""
for arg in "$@"; do
    case "$arg" in
        --list) list_roles; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option: $arg" ;;
        *) role=$arg ;;
    esac
done
[ -n "$role" ] || { usage; exit 2; }
[ -x "roles/$role/install.sh" ] || die "no such role: $role (try ./install.sh --list)"

if [ "$DRY_RUN" = 1 ]; then
    ROOT=${ROOT:-$PWD/dry-run-root}
    ALLOW_EXAMPLE=${ALLOW_EXAMPLE:-1}
    log "dry run: files go to $ROOT, no commands are run"
fi
export ROOT DRY_RUN ALLOW_EXAMPLE

exec "roles/$role/install.sh"
