#!/usr/bin/env bash
# =====================================================================
# Hack Heroes all-in-one supervisor.
# Boots Postgres + GoTrue (auth) + PostgREST (rest) + nginx in one container,
# in order, then runs nginx in the foreground so the container stays alive and
# Easypanel/Traefik can route to :8080.
#
# (No Realtime service — the dashboard uses a polling fallback for live
# updates, which avoids the Realtime/glibc incompatibility. See Dockerfile.)
#
# Order:
#   1. Postgres (official entrypoint; runs init scripts on first boot:
#      schema + service-role passwords).
#   2. Wait until the service roles can log in.
#   3. GoTrue (auth) :9999   [restart loop]
#   4. PostgREST (rest) :3000 [restart loop]
#   5. nginx :8080 (foreground)
# =====================================================================
set -u

export POSTGRES_DB="${POSTGRES_DB:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-hackheroes-dev-postgres-pw}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export JWT_SECRET="${JWT_SECRET:-hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001}"
export JWT_EXP="${JWT_EXP:-3600}"
PW="$POSTGRES_PASSWORD"
SECRET="$JWT_SECRET"
PUBLIC_URL="${PUBLIC_URL:-https://heroes.beonflow.de}"

log() { echo "[hh-supervisor] $*"; }

term() {
  log "shutting down…"
  kill "${NGINX_PID:-0}" "${REST_PID:-0}" "${AUTH_PID:-0}" 2>/dev/null || true
  su - postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data stop -m fast" 2>/dev/null || true
  exit 0
}
trap term TERM INT

# 1) Postgres -----------------------------------------------------------------
log "starting Postgres (official entrypoint)…"
docker-entrypoint.sh postgres -D /etc/postgresql &
PG_ENTRY_PID=$!

log "waiting for Postgres to accept connections…"
i=0
until pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U "$POSTGRES_DB" >/dev/null 2>&1; do
  i=$((i+1))
  if ! kill -0 "$PG_ENTRY_PID" 2>/dev/null; then
    log "FATAL: Postgres entrypoint exited during startup"; exit 1
  fi
  [ "$i" -ge 120 ] && { log "FATAL: Postgres not ready after 240s"; exit 1; }
  sleep 2
done
log "Postgres is accepting connections."

log "waiting for service-role passwords to be set…"
i=0
until PGPASSWORD="$PW" psql -h 127.0.0.1 -U supabase_auth_admin -d "$POSTGRES_DB" -c 'select 1' >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -ge 60 ] && { log "FATAL: service roles never became loginable"; exit 1; }
  sleep 2
done
log "service roles ready."

# 2) GoTrue (auth) :9999 ------------------------------------------------------
# The supabase/postgres base ships a LEGACY partial `auth` schema (5 tables,
# missing auth.identities/sessions/…) with stale schema_migrations, so GoTrue
# v2.151 thinks it's migrated and signup hits "relation identities does not
# exist". We must let GoTrue re-run its bundled migrations
# (/usr/local/etc/auth/migrations).
#
# IMPORTANT: do NOT `drop schema auth cascade` — that drops auth.uid()/role()
# and CASCADE-drops the public RLS policies that reference them. Instead, drop
# only the legacy auth TABLES (keeping auth.uid() and the public policies),
# then GoTrue rebuilds the full table set from scratch.
# Marker file => runs once; idempotent across restarts/redeploys.
AUTH_RESET_MARK=/var/lib/postgresql/data/.hh_auth_reset_done
if [ ! -f "$AUTH_RESET_MARK" ]; then
  log "clearing legacy auth tables so GoTrue migrates the full schema…"
  if PGPASSWORD="$PW" psql -h 127.0.0.1 -U supabase_admin -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<'SQL'
do $$
declare t text;
begin
  -- Drop every table in the auth schema (legacy partial set) WITHOUT touching
  -- functions (auth.uid/role/jwt) or anything in other schemas.
  for t in
    select tablename from pg_tables where schemaname = 'auth'
  loop
    execute format('drop table if exists auth.%I cascade', t);
  end loop;
end $$;
SQL
  then
    touch "$AUTH_RESET_MARK"
    log "legacy auth tables cleared."
  else
    log "WARN: auth table clear failed; continuing."
  fi
fi

log "starting GoTrue (auth) on :9999…"
(
  # Run from the dir that holds ./migrations so GoTrue applies the full schema
  # (auth.identities, sessions, mfa, …) instead of finding none and skipping.
  cd /usr/local/etc/auth || exit 1
  while true; do
    GOTRUE_API_HOST=0.0.0.0 \
    GOTRUE_API_PORT=9999 \
    API_EXTERNAL_URL="$PUBLIC_URL" \
    GOTRUE_DB_DRIVER=postgres \
    GOTRUE_DB_DATABASE_URL="postgres://supabase_auth_admin:${PW}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}?search_path=auth&sslmode=disable" \
    GOTRUE_SITE_URL="$PUBLIC_URL" \
    GOTRUE_URI_ALLOW_LIST='*' \
    GOTRUE_DISABLE_SIGNUP=false \
    GOTRUE_JWT_SECRET="$SECRET" \
    GOTRUE_JWT_EXP="$JWT_EXP" \
    GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    GOTRUE_JWT_ADMIN_ROLES=service_role \
    GOTRUE_JWT_AUD=authenticated \
    GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=true \
    GOTRUE_EXTERNAL_EMAIL_ENABLED=true \
    GOTRUE_MAILER_AUTOCONFIRM=true \
    GOTRUE_SMTP_ADMIN_EMAIL=admin@beonflow.de \
    GOTRUE_SMTP_SENDER_NAME="Hack Heroes" \
      /usr/local/bin/auth 2>&1 | sed 's/^/[auth] /'
    echo "[hh-supervisor] auth exited; restarting in 3s…"; sleep 3
  done
) &
AUTH_PID=$!

# 3) PostgREST (rest) :3000 ---------------------------------------------------
log "starting PostgREST (rest) on :3000…"
(
  while true; do
    PGRST_DB_URI="postgres://authenticator:${PW}@127.0.0.1:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable" \
    PGRST_DB_SCHEMAS=public \
    PGRST_DB_ANON_ROLE=anon \
    PGRST_JWT_SECRET="$SECRET" \
    PGRST_DB_USE_LEGACY_GUCS=false \
    PGRST_SERVER_PORT=3000 \
      /usr/local/bin/postgrest 2>&1 | sed 's/^/[rest] /'
    echo "[hh-supervisor] rest exited; restarting in 3s…"; sleep 3
  done
) &
REST_PID=$!

# 4) nginx :8080 (foreground) -------------------------------------------------
log "starting nginx on :8080 (foreground)…"
nginx -g 'daemon off;' 2>&1 | sed 's/^/[nginx] /' &
NGINX_PID=$!

log "all services launched. waiting on nginx + postgres…"
wait -n "$NGINX_PID" "$PG_ENTRY_PID"
log "nginx or postgres exited; shutting down container."
term
