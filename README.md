# pgbouncer

Centralized connection pooling gateway for all Katisha microservices.
Sits between every application service and the `db` postgres container on `katisha-net`.

---

## Architecture

```
[microservice]  →  pgbouncer:6432  →  db:5432
```

- **Pool mode: transaction** — mandatory for Prisma and stateless services. Each SQL
  statement can use a different backend connection; Prisma's `?pgbouncer=true` flag
  disables prepared statements and advisory locks that transaction mode can't handle.
- **max_client_conn = 1000** — how many client connections pgbouncer accepts total.
- **default_pool_size = 20 / reserve_pool_size = 5** — pgbouncer maintains up to 20
  backend connections per database by default; under burst load it can borrow 5 more.
- **max_db_connections = 25** — hard ceiling on backend connections per database.
  This means postgres never sees more than 25 × (number of databases) connections
  from pgbouncer, keeping postgres well within its `max_connections` budget.

---

## Auth design (auth_query)

Rather than storing every user's password in `userlist.txt`, pgbouncer authenticates
clients by calling `public.get_auth($1)` on postgres — a `SECURITY DEFINER` function
that reads `pg_shadow` without needing superuser access. Only `pgbouncer_auth` itself
needs to be in `userlist.txt`.

```
client connects
  → pgbouncer looks up client's hash via get_auth()  (runs as pgbouncer_auth)
  → performs SCRAM-SHA-256 exchange with client
  → proxies to postgres backend
```

`auth_dbname = katisha-db` routes all `get_auth()` calls to the admin database,
so the function only needs to exist in one place.

---

## Adding a new database

1. Add a line to `config/pgbouncer.ini` under `[databases]`:
   ```ini
   orders = host=db port=5432 dbname=orders_db
   ```
2. Commit and push. The pipeline sends SIGHUP — **no restart, no dropped connections**.

---

## Secrets

| Secret | Where | Used for |
|---|---|---|
| `PGBOUNCER_AUTH_PASSWORD` | **GitHub** (this repo) | — (not needed here, lives in db repo) |
| `PGBOUNCER_AUTH_PASSWORD` | **GitHub** (db repo) | `ALTER USER pgbouncer_auth WITH PASSWORD` |
| `PGBOUNCER_AUTH_PASSWORD` | **Infisical** `/pgbouncer` | `userlist.txt` generation in `deploy.sh` |

`PGBOUNCER_AUTH_PASSWORD` is the only secret this service needs. It must be stored in
both the db repo's GitHub secrets (so the db deploy can set the postgres password) **and**
in Infisical at `/pgbouncer` (so deploy.sh can generate `userlist.txt`).

---

## How the deploy pipeline works

On every push to `main`:

1. SSH into the server, pull latest code.
2. Authenticate with Infisical, inject `PGBOUNCER_AUTH_PASSWORD`.
3. `deploy.sh` generates `config/userlist.txt` (plaintext password — never committed).
4. **If pgbouncer is running:** `docker kill --signal=HUP pgbouncer` — pgbouncer
   re-reads `pgbouncer.ini` and `userlist.txt` instantly with zero downtime.
5. **If pgbouncer is stopped:** `docker compose up -d`.

The SIGHUP path means a password rotation or a new database entry never interrupts
live connections.

---

## Connecting a Prisma service

```env
DATABASE_URL="postgresql://<user>:<password>@pgbouncer:6432/<dbname>?pgbouncer=true&connect_timeout=5&pool_timeout=5"
```

The `?pgbouncer=true` flag tells Prisma to:
- Disable prepared statements (incompatible with transaction-mode pooling)
- Disable advisory locks
- Disable `SET` commands that don't survive connection reuse

Example for the future `orders` service:
```env
DATABASE_URL="postgresql://orders_user:secret@pgbouncer:6432/orders?pgbouncer=true&connect_timeout=5&pool_timeout=5"
```

---

## Local Infisical run

```bash
export PATH="$HOME/.local/bin:$PATH"
INFISICAL_TOKEN=$(infisical login \
  --method=universal-auth \
  --client-id=<id> \
  --client-secret=<secret> \
  --domain=http://localhost:8080 \
  --plain --silent)

infisical run \
  --token="$INFISICAL_TOKEN" \
  --projectId=<project-id> \
  --env=dev \
  --path=/pgbouncer \
  --domain=http://localhost:8080 \
  -- sh deploy.sh
```

---

## Admin console

```bash
# Connect to pgbouncer's virtual admin database
psql -h <server-ip> -p 6432 -U pgbouncer_auth pgbouncer

# Useful commands
SHOW pools;
SHOW stats;
SHOW clients;
SHOW servers;
RELOAD;   -- same effect as SIGHUP
```

Note: pgbouncer's port 6432 is not exposed to the host. Use `docker exec` or an SSH
tunnel to reach the admin console from outside the server.

```bash
# Via docker exec
docker exec -it pgbouncer psql -h 127.0.0.1 -p 6432 -U pgbouncer_auth pgbouncer
```
