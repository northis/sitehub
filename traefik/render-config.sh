#!/bin/sh
# Renders the Traefik static configuration template with instance-specific
# values from the environment (.env, passed by docker-compose).
#
# Why this exists: Traefik v3 does not expand ${...} placeholders in the
# static configuration file, and when a configuration file is present it
# ignores install options from CLI flags and environment variables. So the
# template is rendered into /etc/traefik/traefik.yml at container start.
set -e

# Optional Access JWT verification (see .env.example): the websecure
# entrypoint middleware list gets cf-access-verify@file when it is on,
# and stays untouched otherwise.
if [ "${CF_ACCESS_VERIFY_GLOBAL:-false}" = "true" ]; then
  CF_ACCESS_VERIFY_MIDDLEWARE="- cf-access-verify@file"
else
  CF_ACCESS_VERIFY_MIDDLEWARE=""
fi

sed -e 's|${DOMAIN}|'"$DOMAIN"'|g' \
    -e 's|${LE_EMAIL}|'"$LE_EMAIL"'|g' \
    -e 's|${LE_CA_SERVER}|'"$LE_CA_SERVER"'|g' \
    -e 's|${CF_ACCESS_VERIFY_MIDDLEWARE}|'"$CF_ACCESS_VERIFY_MIDDLEWARE"'|g' \
    /etc/traefik/traefik.yml.tmpl > /etc/traefik/traefik.yml

exec traefik
