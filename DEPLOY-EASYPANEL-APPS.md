# Deploying Hack Heroes on Easypanel — 5 App services

This is the **most reliable** Easypanel path: deploy the stack as **5 separate
App services** from prebuilt public images. App services are auto-attached to
Easypanel's Traefik network, which avoids the Compose-network 502 problem.

There are **no init/one-shot containers** — the database image sets the
Supabase role passwords on first boot, and the realtime image self-registers
its tenants on boot.

> Use this if the **Compose** service gave you a 502. If you already have a
> Compose service for Hack Heroes, **delete it first** so nothing fights over
> the domain.

---

## Images (public on ghcr.io)

| Service | Image |
| --- | --- |
| db       | `ghcr.io/oldjoba/hackheroes-db:latest`       (postgres + schema + role passwords baked in) |
| auth     | `supabase/gotrue:v2.151.0`                    (stock) |
| rest     | `postgrest/postgrest:v12.2.0`                 (stock) |
| realtime | `ghcr.io/oldjoba/hackheroes-realtime:latest`  (realtime + tenant self-registration) |
| site     | `ghcr.io/oldjoba/hackheroes-site:latest`      (nginx + app + prod config + gateway) |

Shared secrets (demo values; same across services):

```
POSTGRES_PASSWORD / db password = hackheroes-dev-postgres-pw
JWT_SECRET                      = hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001
ADMIN_JWT (service_role JWT)    = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwiaWF0IjoxNzA0MDY3MjAwLCJleHAiOjIwMTk2NjcyMDAsInJvbGUiOiJzZXJ2aWNlX3JvbGUifQ.aNz9ykNuOLKiGMY_fszQIfiQQEcezpJHCIpVCVVBORs
```

**Service-to-service hostnames:** in the same Easypanel project, services reach
each other by service name. If your Easypanel prefixes names, use that exact
name everywhere a host is referenced below (db / auth / rest / realtime).
The defaults below assume the names are literally `db`, `auth`, `rest`,
`realtime`, `site`.

---

## Step 1 — `db` (create FIRST)

- **+ Service → App** → name **`db`**.
- **Source:** Image → `ghcr.io/oldjoba/hackheroes-db:latest`
- **Environment:**
  ```
  POSTGRES_DB=postgres
  POSTGRES_PASSWORD=hackheroes-dev-postgres-pw
  POSTGRES_PORT=5432
  JWT_SECRET=hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001
  JWT_EXP=3600
  ```
- **Volume (persist data):** mount a volume at `/var/lib/postgresql/data`.
- **No domain.** Deploy. Wait until logs show `database system is ready to
  accept connections` and `[zzz-zzz-roles] done.`

---

## Step 2 — `auth`

- **+ Service → App** → name **`auth`** → Image `supabase/gotrue:v2.151.0`
- **Environment:**
  ```
  GOTRUE_API_HOST=0.0.0.0
  GOTRUE_API_PORT=9999
  API_EXTERNAL_URL=https://heroes.beonflow.de
  GOTRUE_DB_DRIVER=postgres
  GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:hackheroes-dev-postgres-pw@db:5432/postgres?search_path=auth&sslmode=disable
  GOTRUE_SITE_URL=https://heroes.beonflow.de
  GOTRUE_URI_ALLOW_LIST=*
  GOTRUE_DISABLE_SIGNUP=false
  GOTRUE_JWT_SECRET=hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001
  GOTRUE_JWT_EXP=3600
  GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
  GOTRUE_JWT_ADMIN_ROLES=service_role
  GOTRUE_JWT_AUD=authenticated
  GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=true
  GOTRUE_EXTERNAL_EMAIL_ENABLED=true
  GOTRUE_MAILER_AUTOCONFIRM=true
  GOTRUE_SMTP_ADMIN_EMAIL=admin@beonflow.de
  GOTRUE_SMTP_SENDER_NAME=Hack Heroes
  ```
- **No domain.** Deploy. Logs should end with `GoTrue API started on: 0.0.0.0:9999`.

---

## Step 3 — `rest`

- **+ Service → App** → name **`rest`** → Image `postgrest/postgrest:v12.2.0`
- **Environment:**
  ```
  PGRST_DB_URI=postgres://authenticator:hackheroes-dev-postgres-pw@db:5432/postgres?sslmode=disable
  PGRST_DB_SCHEMAS=public
  PGRST_DB_ANON_ROLE=anon
  PGRST_JWT_SECRET=hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001
  PGRST_DB_USE_LEGACY_GUCS=false
  ```
- **No domain.** Deploy.

---

## Step 4 — `realtime`

- **+ Service → App** → name **`realtime`** → Image `ghcr.io/oldjoba/hackheroes-realtime:latest`
- **Environment:**
  ```
  PORT=4000
  DB_HOST=db
  DB_PORT=5432
  DB_USER=supabase_admin
  DB_PASSWORD=hackheroes-dev-postgres-pw
  DB_NAME=postgres
  DB_AFTER_CONNECT_QUERY=SET search_path TO realtime
  DB_ENC_KEY=supabaserealtime
  API_JWT_SECRET=hackheroes-super-secret-dev-jwt-secret-min-32-chars-long-0001
  SECRET_KEY_BASE=hackheroes-dev-realtime-secret-key-base-please-change-0000000001
  ERL_AFLAGS=-proto_dist inet_tcp
  DNS_NODES=''
  RLIMIT_NOFILE=10000
  APP_NAME=realtime
  SEED_SELF_HOST=true
  RUN_JANITOR=true
  TENANT_EXTERNAL_IDS=heroes.beonflow.de,heroes,localhost
  ADMIN_JWT=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwiaWF0IjoxNzA0MDY3MjAwLCJleHAiOjIwMTk2NjcyMDAsInJvbGUiOiJzZXJ2aWNlX3JvbGUifQ.aNz9ykNuOLKiGMY_fszQIfiQQEcezpJHCIpVCVVBORs
  ```
- **No domain.** Deploy. Logs should show
  `[register-tenant] registering 'heroes.beonflow.de' … -> HTTP 201` (x3).

---

## Step 5 — `site`  (this one gets the domain)

- **+ Service → App** → name **`site`** → Image `ghcr.io/oldjoba/hackheroes-site:latest`
- **No environment needed** (prod config is baked in).
- **Domains:** add **`heroes.beonflow.de`** → **Port `8080`** → HTTPS on.
- Deploy.

Open **https://heroes.beonflow.de** — the game loads. nginx in `site` proxies
`/auth/v1`, `/rest/v1`, `/realtime/v1` to the `auth`/`rest`/`realtime` services
by name on the internal network.

---

## Verify

1. `https://heroes.beonflow.de/teacher.html` → register → create class → assign.
2. Open the class **Leaderboard**.
3. Incognito → join link → nickname → solve a challenge → dashboard updates live.

---

## Troubleshooting

- **502 on the domain:** the `site` service must be **Running** and the domain
  bound to **port 8080**. App services attach to Traefik automatically, so once
  `site` is up the 502 clears.
- **Teacher signup fails / Network calls hit localhost:** shouldn't happen —
  prod config is baked into the `site` image. Hard-refresh.
- **Leaderboard doesn't update:** check `realtime` logs for the three
  `HTTP 201` registrations. If the service name isn't `realtime`, update
  nginx’s upstream — but with the default names it just works.
- **Service names differ (Easypanel prefixes):** if Easypanel names a service
  e.g. `myproj_db`, the other services must reference that exact host. Easiest
  is to name them exactly `db`, `auth`, `rest`, `realtime`, `site`.
- **Reset DB:** delete the `db` service’s volume and redeploy `db` (re-runs
  schema + role passwords on a fresh volume).
