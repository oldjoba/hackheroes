#!/bin/sh
# =====================================================================
# Hack Heroes self-host — one-shot role password setup.
# Runs as the privileged superuser (supabase_admin) AFTER the database
# is healthy and BEFORE auth/rest/realtime connect. On this image the
# service roles ship without a password; the supautils extension blocks
# non-superusers (incl. the default "postgres" role) from setting them,
# so we must do it as supabase_admin.
#
# Idempotent: safe to run on every `docker compose up`.
# =====================================================================
set -eu

PW="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"
HOST="${DB_HOST:-db}"
DB="${POSTGRES_DB:-postgres}"

echo "[setup-roles] aligning Supabase service-role passwords…"

PGPASSWORD="$PW" psql -v ON_ERROR_STOP=1 -U supabase_admin -h "$HOST" -d "$DB" <<SQL
alter role supabase_auth_admin     with login password '${PW}';
alter role authenticator           with login password '${PW}';
alter role supabase_admin          with login password '${PW}';
do \$\$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_storage_admin') then
    execute 'alter role supabase_storage_admin with login password ''${PW}''';
  end if;
  if exists (select 1 from pg_roles where rolname = 'supabase_realtime_admin') then
    execute 'alter role supabase_realtime_admin with login password ''${PW}''';
  end if;
end
\$\$;
SQL

echo "[setup-roles] done."
