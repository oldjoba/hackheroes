#!/bin/bash
# Set passwords on Supabase service roles at DB init time, AS supabase_admin
# (the only superuser; supautils blocks others from ALTERing reserved roles).
# Runs in /docker-entrypoint-initdb.d/* (sorts last). During init the local
# socket trusts the superuser, so no password is needed to connect.
set -e
PW="${POSTGRES_PASSWORD:?}"
echo "[zzz-zzz-roles] setting service-role passwords as supabase_admin…"
psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres <<SQL
alter role supabase_auth_admin  with login password '${PW}';
alter role authenticator        with login password '${PW}';
alter role supabase_admin       with login password '${PW}';
do \$\$
begin
  if exists (select 1 from pg_roles where rolname='supabase_storage_admin') then
    execute 'alter role supabase_storage_admin with login password ''${PW}''';
  end if;
  if exists (select 1 from pg_roles where rolname='supabase_realtime_admin') then
    execute 'alter role supabase_realtime_admin with login password ''${PW}''';
  end if;
end
\$\$;
SQL
echo "[zzz-zzz-roles] done."
