#!/bin/sh
set -e

# Generate userlist.txt from the Infisical-injected secret.
# Only pgbouncer_auth lives here — all other users are resolved at login time via auth_query.
# Plaintext format is intentional: pgbouncer needs the plaintext to perform the SCRAM
# handshake with the postgres backend. This file is never committed (see .gitignore).
printf '"pgbouncer_auth" "%s"\n' "$PGBOUNCER_AUTH_PASSWORD" > config/userlist.txt

if docker inspect pgbouncer > /dev/null 2>&1; then
  # Container is running — reload config in place via SIGHUP.
  # PgBouncer re-reads pgbouncer.ini and userlist.txt immediately.
  # Existing client connections are never dropped.
  docker kill --signal=HUP pgbouncer
  echo "pgbouncer config reloaded via SIGHUP — no connections dropped."
else
  # First deploy or container was stopped — bring it up.
  docker compose up -d
fi
