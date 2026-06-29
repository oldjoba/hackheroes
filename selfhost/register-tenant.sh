#!/bin/sh
# =====================================================================
# Hack Heroes — realtime tenant self-registration (App-service deploy).
#
# Runs INSIDE the realtime container, in the background, on boot. Waits for
# the Realtime API to come up, then registers every host form in
# TENANT_EXTERNAL_IDS so the leaderboard websocket resolves regardless of how
# the request Host is parsed. Idempotent (409 = already present = OK).
#
# This replaces the separate realtime-setup container, so the stack can be
# deployed as plain single-container Easypanel "App" services.
# =====================================================================
set -u

RT="http://127.0.0.1:${PORT:-4000}"
IDS="${TENANT_EXTERNAL_IDS:-${TENANT_EXTERNAL_ID:-localhost}}"
SECRET="${API_JWT_SECRET:?API_JWT_SECRET required}"
ADMIN_JWT="${ADMIN_JWT:?ADMIN_JWT required}"
RDB_HOST="${DB_HOST:-db}"
RDB_NAME="${DB_NAME:-postgres}"
RDB_PASS="${DB_PASSWORD:?DB_PASSWORD required}"

echo "[register-tenant] waiting for Realtime API at ${RT} …"
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "${RT}/" 2>/dev/null)" != "000" ] \
      || [ "$i" -ge 90 ]; do
  i=$((i+1)); sleep 2
done

register() {
  ext="$1"
  echo "[register-tenant] registering '${ext}' …"
  code=$(curl -s -o /tmp/rt.out -w '%{http_code}' -X POST "${RT}/api/tenants" \
    -H "Authorization: Bearer ${ADMIN_JWT}" \
    -H "Content-Type: application/json" \
    -d "{\"tenant\":{\"external_id\":\"${ext}\",\"name\":\"${ext}\",\"jwt_secret\":\"${SECRET}\",\"extensions\":[{\"type\":\"postgres_cdc_rls\",\"settings\":{\"db_host\":\"${RDB_HOST}\",\"db_name\":\"${RDB_NAME}\",\"db_port\":\"5432\",\"db_user\":\"supabase_admin\",\"db_password\":\"${RDB_PASS}\",\"region\":\"us-east-1\",\"poll_interval_ms\":100,\"poll_max_changes\":100,\"poll_max_record_bytes\":1048576,\"ssl_enforced\":false,\"publication\":\"supabase_realtime\",\"slot_name\":\"supabase_realtime_replication_slot\"}}]}}")
  echo "[register-tenant]   -> HTTP ${code}"
}

echo "[register-tenant] tenant ids: ${IDS}"
OLDIFS="$IFS"; IFS=','
for ext in $IDS; do
  ext="$(echo "$ext" | tr -d ' ')"
  [ -n "$ext" ] && register "$ext"
done
IFS="$OLDIFS"
echo "[register-tenant] done."
