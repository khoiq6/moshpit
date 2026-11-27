#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
umask 077
if [ ! -e .env ]; then
    printf 'GUAC_DB_PASSWORD=%s\n' "$(openssl rand -hex 32)" > .env
fi
if [ ! -s initdb.sql ]; then
    tmp="$(mktemp ./initdb.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql > "$tmp"
    test -s "$tmp"
    mv "$tmp" initdb.sql
    trap - EXIT
fi
docker compose config --quiet
docker compose up -d
printf '%s\n' 'Local gateway: http://127.0.0.1:8080/guacamole/' 'Use SSH port forwarding for initial admin login and change the default password before exposing via HTTPS.'
