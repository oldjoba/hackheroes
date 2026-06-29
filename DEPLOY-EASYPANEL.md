# Deploying Hack Heroes on Easypanel

This deploys the **full stack** (game + teacher/student classroom + live
leaderboard) on an Easypanel VPS, served at **https://heroes.beonflow.de**.

> Why your earlier deploy didn't open: you used an Easypanel **App** service,
> which builds only the `Dockerfile` (the nginx site) and ignores
> `docker-compose.yml`. So only the front-end ran, and nothing routed the
> domain to it. The steps below use a **Compose** service instead, which runs
> the whole stack, and map the domain in the Easypanel UI.

---

## What's in the repo for this

| File | Purpose |
| --- | --- |
| `docker-compose.easypanel.yml` | The stack for Easypanel (db, auth, rest, realtime, site). No host ports — Easypanel's Traefik fronts it. |
| `config/supabase.prod.json` | Front-end config pointing the browser at `https://heroes.beonflow.de`. Mounted over `config/supabase.json` by the compose file. |
| `Dockerfile` / `nginx.conf` | The `site` image: serves the static app **and** reverse-proxies `/auth/v1`, `/rest/v1`, `/realtime/v1` to the backend, so the browser uses one origin. |

The browser only ever talks to `https://heroes.beonflow.de`. nginx inside the
`site` container forwards API/websocket traffic to the backend services on the
internal Docker network.

---

## Step 1 — DNS

Point the domain at your VPS (same IP as your other sites):

```
A   heroes.beonflow.de   ->   <your VPS public IP>
```

Wait until it resolves (`dig +short heroes.beonflow.de` returns the IP).

---

## Step 2 — Create a Compose service in Easypanel

1. In your Easypanel project, click **+ Service → Compose**.
2. **Source:** connect the GitHub repo `oldjoba/hackheroes` (branch `main`).
3. **Compose file path:** set it to:
   ```
   docker-compose.easypanel.yml
   ```
4. Click **Deploy**. Easypanel builds the `site` image and starts all services.
   First build pulls the Supabase images, so give it a few minutes.

---

## Step 3 — Map the domain to the `site` service

This is the step that makes the page open.

1. Open the Compose service → **Domains** tab.
2. Add a domain binding:
   - **Host:** `heroes.beonflow.de`
   - **Service:** `site`
   - **Port:** `8080`   ← the port nginx listens on inside the container
   - **HTTPS:** enabled (Easypanel/Traefik issues a free Let's Encrypt cert)
3. Save. Within a minute Traefik routes `https://heroes.beonflow.de` → `site:8080`.

Open **https://heroes.beonflow.de** — the game should load.

---

## Step 4 — Verify the classroom backend

1. Go to **https://heroes.beonflow.de/teacher.html** → register (email +
   password) → create a class → assign a couple of challenges.
2. Open the class **Leaderboard** link (`dashboard.html?class=...`).
3. In another browser/incognito, open the **join link**
   (`https://heroes.beonflow.de/join.html?code=YOUR-CODE`), pick a nickname,
   solve a challenge — the dashboard should update **live**.

If the leaderboard updates in real time, everything (auth, data API, and the
realtime websocket) is working end to end.

---

## Troubleshooting

**Page still won't open**
- Domains tab: confirm the binding targets service **`site`**, port **`8080`**
  (not 80). The container listens on 8080.
- Check the `site` service logs in Easypanel — nginx should show it started.
  Healthcheck requests from `127.0.0.1` (User-Agent `Wget`) are normal.
- Confirm DNS resolves to this VPS and the cert was issued (Easypanel shows
  cert status on the domain).

**Page loads, but teacher login / join / leaderboard fail**
- Open the browser devtools **Network** tab on `teacher.html`. Requests should
  go to `https://heroes.beonflow.de/auth/v1/...` and `/rest/v1/...` and return
  2xx. If they hit `localhost`, the `site` didn't get
  `config/supabase.prod.json` — redeploy so the volume mount applies.
- 401/403 on `/rest/v1` is normal for unauthenticated calls; the app sends the
  anon key automatically.

**Live leaderboard doesn't update (websocket fails)**
- The realtime tenant must match the domain. The `realtime-setup` service
  registers `heroes.beonflow.de`, `heroes`, and `localhost`. Check its logs —
  it should print `HTTP 201` (or `409` if already present) for each.
- If you change the domain later, update `TENANT_EXTERNAL_IDS` in
  `docker-compose.easypanel.yml` **and** `url` in `config/supabase.prod.json`,
  then redeploy. If the tenant was created under the old name, recreate the
  stack so it reseeds (this wipes the DB — see below).

**Reset the database (wipes classes/students/progress)**
- In Easypanel, stop the Compose service, delete its **volume** (`hh-db-data`),
  and redeploy. The schema, role passwords, and realtime tenants are recreated
  automatically on a fresh volume.

---

## Security note

The committed `.env`-style values (JWT secret, DB password, anon/service keys)
are **shared dev secrets** baked into `docker-compose.easypanel.yml`. They are
fine for a classroom/demo deployment behind RLS, but for anything sensitive you
should regenerate them:

1. Pick a new strong `JWT_SECRET` (32+ chars).
2. Regenerate the matching `anon` and `service_role` JWTs (HS256, payload
   `{"role":"anon"}` / `{"role":"service_role"}`) and update `ADMIN_JWT`,
   `config/supabase.prod.json` `anonKey`, and every `*_JWT_SECRET` reference.
3. Change `POSTGRES_PASSWORD` everywhere it appears.

---

## Changing the domain

If you move off `heroes.beonflow.de`, update these and redeploy:

- `config/supabase.prod.json` → `url`
- `docker-compose.easypanel.yml` → `SITE_URL`, `API_EXTERNAL_URL`,
  `GOTRUE_SITE_URL`, and `TENANT_EXTERNAL_IDS` (add the new host + its first label)
- Easypanel **Domains** tab → the new host bound to `site:8080`
