#!/bin/sh
# =====================================================================
# Hack Heroes self-host — register the Realtime tenant.
# Self-hosted Realtime is multi-tenant. supabase-js derives the tenant
# external_id from the site URL host ("localhost"), so we must create a
# tenant with that external_id pointing at our database, signed with our
# JWT secret. Realtime encrypts the DB settings itself.
#
# Idempotent: if the tenant already exists, Realtime returns it / 201 and
# we treat that as success.
# =====================================================================
set -eu

RT="${REALTIME_URL:-http://realtime:4000}"
EXT="${TENANT_EXTERNAL_ID:-localhost}"
JWT_SECRET="${JWT_SECRET:?JWT_SECRET required}"
ADMIN_JWT="${ADMIN_JWT:?ADMIN_JWT required}"
DB_HOST="${DB_HOST:-db}"
DB_NAME="${POSTGRES_DB:-postgres}"
DB_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"

echo "[realtime-setup] waiting for Realtime API at ${RT} …"
i=0
# Realtime answers '/' once it's up (any HTTP status, incl. 404/401, means
# the server is listening). We only need the socket to respond.
until [ -n "$(curl -s -o /dev/null -w '%{http_code}' "${RT}/" 2>/dev/null)" ] \
      && [ "$(curl -s -o /dev/null -w '%{http_code}' "${RT}/" 2>/dev/null)" != "000" ] \
      || [ "$i" -ge 60 ]; do
  i=$((i+1)); sleep 2
done

echo "[realtime-setup] registering tenant '${EXT}' …"
code=$(curl -s -o /tmp/rt.out -w '%{http_code}' -X POST "${RT}/api/tenants" \
  -H "Authorization: Bearer ${ADMIN_JWT}" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenant\": {
      \"external_id\": \"${EXT}\",
      \"name\": \"${EXT}\",
      \"jwt_secret\": \"${JWT_SECRET}\",
      \"extensions\": [{
        \"type\": \"postgres_cdc_rls\",
        \"settings\": {
          \"db_host\": \"${DB_HOST}\",
          \"db_name\": \"${DB_NAME}\",
          \"db_port\": \"5432\",
          \"db_user\": \"supabase_admin\",
          \"db_password\": \"${DB_PASSWORD}\",
          \"region\": \"us-east-1\",
          \"poll_interval_ms\": 100,
          \"poll_max_changes\": 100,
          \"poll_max_record_bytes\": 1048576,
          \"ssl_enforced\": false,
          \"publication\": \"supabase_realtime\",
          \"slot_name\": \"supabase_realtime_replication_slot\"
        }
      }]
    }
  }")

echo "[realtime-setup] Realtime responded HTTP ${code}"
# 200/201 = created/updated; 409 or similar = already exists. All fine.
case "$code" in
  2*|409) echo "[realtime-setup] tenant ready."; exit 0 ;;
  *) echo "[realtime-setup] unexpected response:"; cat /tmp/rt.out; echo;
     # Don't hard-fail the whole stack on a transient hiccup.
     exit 0 ;;
esac
