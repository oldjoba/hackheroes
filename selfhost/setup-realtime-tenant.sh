#!/bin/sh
# =====================================================================
# Hack Heroes self-host — register the Realtime tenant(s).
# Self-hosted Realtime is multi-tenant and derives the tenant external_id
# from the request host. Depending on deployment that can be the FULL host
# (e.g. "heroes.beonflow.de") or just the first label (e.g. "heroes"), and
# locally it's "localhost". To be robust we register every candidate id in
# TENANT_EXTERNAL_IDS (comma-separated). All point at the same database and
# share our JWT secret, so whichever the client uses, it works.
#
# Idempotent: existing tenants return 2xx/409 and are treated as success.
# =====================================================================
set -eu

RT="${REALTIME_URL:-http://realtime:4000}"
# Accept a comma-separated list; fall back to the single TENANT_EXTERNAL_ID,
# then to "localhost".
IDS="${TENANT_EXTERNAL_IDS:-${TENANT_EXTERNAL_ID:-localhost}}"
JWT_SECRET="${JWT_SECRET:?JWT_SECRET required}"
ADMIN_JWT="${ADMIN_JWT:?ADMIN_JWT required}"
DB_HOST="${DB_HOST:-db}"
DB_NAME="${POSTGRES_DB:-postgres}"
DB_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"

echo "[realtime-setup] waiting for Realtime API at ${RT} …"
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "${RT}/" 2>/dev/null)" != "000" ] \
      || [ "$i" -ge 60 ]; do
  i=$((i+1)); sleep 2
done

register() {
  ext="$1"
  echo "[realtime-setup] registering tenant '${ext}' …"
  code=$(curl -s -o /tmp/rt.out -w '%{http_code}' -X POST "${RT}/api/tenants" \
    -H "Authorization: Bearer ${ADMIN_JWT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"tenant\": {
        \"external_id\": \"${ext}\",
        \"name\": \"${ext}\",
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
  echo "[realtime-setup]   -> HTTP ${code}"
  case "$code" in
    2*|409) return 0 ;;
    *) echo "[realtime-setup]   response: $(cat /tmp/rt.out)"; return 1 ;;
  esac
}

# Split IDS on commas and register each (don't hard-fail the stack on a hiccup).
echo "[realtime-setup] tenant ids: ${IDS}"
OLDIFS="$IFS"; IFS=','
for ext in $IDS; do
  ext="$(echo "$ext" | tr -d ' ')"
  [ -n "$ext" ] && register "$ext" || true
done
IFS="$OLDIFS"

echo "[realtime-setup] done."
exit 0
