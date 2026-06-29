# Deploying Hack Heroes on Easypanel

Deploys the **full stack** (game + teacher/student classroom + live leaderboard)
on an Easypanel VPS at **https://heroes.beonflow.de**, using prebuilt images
from GitHub Container Registry. **Nothing to build** — you paste one compose
file and map the domain.

> **Why the earlier deploys failed**
> - An Easypanel **App** service builds only a single `Dockerfile` (the nginx
>   site) — so only the front-end ran, with nothing behind it.
> - A **Compose** service pointed at a repo tried to *build the compose file as
>   a Dockerfile* (`unknown instruction: services:`). Compose services don't
>   build from the repo — you paste the YAML into their **Content** field.
>
> This guide uses a **Compose** service with **paste-ready** content and
> **image-only** services, so there's no build and no repo file access needed.

---

## How it works

| Piece | What it is |
| --- | --- |
| `ghcr.io/oldjoba/hackheroes-site` | nginx + the static app. The **production config** (browser → `https://heroes.beonflow.de`) is **baked in**. nginx also reverse-proxies `/auth/v1`, `/rest/v1`, `/realtime/v1` to the backend, so the browser uses **one origin**. |
| `ghcr.io/oldjoba/hackheroes-db` | `supabase/postgres` with the **classroom schema baked in** (auto-applied on first boot). |
| `supabase/gotrue`, `postgrest`, `supabase/realtime` | Stock Supabase services (auth, data API, realtime). |
| `db-setup`, `realtime-setup` | One-shot init containers. Their scripts are **inlined** in the compose `Content`, so no files are mounted. |

The browser only ever talks to `https://heroes.beonflow.de`.

---

## Step 1 — DNS

Point the domain at your VPS (same IP as your other sites):

```
A   heroes.beonflow.de   ->   <your VPS public IP>
```

Wait until `dig +short heroes.beonflow.de` returns the IP.

---

## Step 2 — Create a Compose service and paste the stack

1. In your Easypanel project: **+ Service → Compose**.
2. In the **Content** field, paste the **entire** contents of
   [`docker-compose.easypanel.yml`](docker-compose.easypanel.yml) from this repo.
   (Do **not** connect it to the repo — Compose services run the pasted YAML
   directly. Everything it needs comes from ghcr.io and inline scripts.)
3. Click **Deploy**.

First deploy pulls the images and runs the init containers (db schema, role
passwords, realtime tenants). Give it 1–3 minutes. In the logs you should see:

```
[db-setup] done.
[realtime-setup] registering tenant 'heroes.beonflow.de' …  -> HTTP 201
[realtime-setup] done.
```

> **Images must be public.** The two `ghcr.io/oldjoba/hackheroes-*` packages are
> public, so Easypanel pulls them with no credentials. (If you ever fork these,
> set your own packages to Public, or add ghcr registry credentials in Easypanel.)

---

## Step 3 — Map the domain to the `site` service

This is the step that makes the page open.

1. Open the Compose service → **Domains** tab → **Add domain**:
   - **Host:** `heroes.beonflow.de`
   - **Service:** `site`
   - **Port:** `8080`   ← the port nginx listens on inside the container
   - **HTTPS:** enabled (Easypanel/Traefik issues a free Let's Encrypt cert)
2. Save. Within ~1 min, Traefik routes `https://heroes.beonflow.de` → `site:8080`.

Open **https://heroes.beonflow.de** — the game should load.

---

## Step 4 — Verify the classroom backend

1. **https://heroes.beonflow.de/teacher.html** → register (email + password) →
   create a class → assign a couple of challenges.
2. Open the class **Leaderboard** (`dashboard.html?class=...`).
3. In an incognito window, open the **join link**
   (`https://heroes.beonflow.de/join.html?code=YOUR-CODE`), pick a nickname,
   solve a challenge — the dashboard updates **live**.

If the leaderboard updates in real time, auth + data API + the realtime
websocket are all working end to end.

---

## Troubleshooting

**Page won't open**
- Domains tab: binding must target service **`site`**, port **`8080`** (not 80).
- Check `site` logs — nginx should be started. Healthcheck hits from
  `127.0.0.1` (User-Agent `Wget`) are normal.
- Confirm DNS resolves to this VPS and the cert was issued.

**Page loads, but teacher login / join / leaderboard fail**
- Devtools **Network** on `teacher.html`: requests should go to
  `https://heroes.beonflow.de/auth/v1/...` and `/rest/v1/...` (not `localhost`)
  and return 2xx. The prod config is baked into the `site` image, so they
  should never hit `localhost`.
- 401/403 on `/rest/v1` for unauthenticated calls is normal — the app sends the
  anon key automatically.

**Image pull fails (`denied` / `not found`)**
- The ghcr packages must be **Public**:
  - https://github.com/users/oldjoba/packages/container/hackheroes-site/settings
  - https://github.com/users/oldjoba/packages/container/hackheroes-db/settings
  - Danger Zone → Change visibility → **Public**.

**Live leaderboard doesn't update (websocket fails)**
- The realtime tenant must match the domain. `realtime-setup` registers
  `heroes.beonflow.de`, `heroes`, and `localhost`. Check its logs for `HTTP 201`
  (or it's already present) on each.
- If you change the domain later, update `TENANT_EXTERNAL_IDS` in the pasted
  compose **and** the `url` in the site image's baked config, then redeploy.
  (Changing the baked config means rebuilding/re-pushing the site image — see
  "Changing the domain" below.)

**Reset the database (wipes classes/students/progress)**
- Stop the Compose service, delete its **volume** (`hh-db-data`), redeploy.
  Schema, role passwords, and realtime tenants are recreated on a fresh volume.

---

## Security note

The values in the compose (JWT secret, DB password, anon/service keys) are
**shared dev/demo secrets** (also in this public repo). Fine for a classroom
demo behind RLS. To harden:

1. Pick a new strong `JWT_SECRET` (32+ chars).
2. Regenerate the matching `anon` and `service_role` JWTs (HS256, payloads
   `{"role":"anon"}` / `{"role":"service_role"}`), update `ADMIN_JWT` in the
   compose, and rebuild the **site** image with the new `anonKey` in
   `config/supabase.prod.json`.
3. Change `POSTGRES_PASSWORD` everywhere it appears.

---

## Rebuilding / re-publishing the images (maintainers)

The images are built for **linux/amd64** (Easypanel VPS arch) and pushed to ghcr:

```bash
# from the repo root, logged in to ghcr (docker login ghcr.io)
docker buildx build --platform linux/amd64 -f Dockerfile.prod \
  -t ghcr.io/oldjoba/hackheroes-site:latest --push .

docker buildx build --platform linux/amd64 -f selfhost/Dockerfile.db \
  -t ghcr.io/oldjoba/hackheroes-db:latest --push selfhost/
```

Then redeploy the Easypanel Compose service to pull the new images.

---

## Changing the domain

If you move off `heroes.beonflow.de`:

1. In `config/supabase.prod.json` → set `url` to the new domain; rebuild +
   re-push the **site** image (commands above).
2. In the pasted compose `Content`: update `API_EXTERNAL_URL`, `GOTRUE_SITE_URL`,
   and `TENANT_EXTERNAL_IDS` (add the new host + its first label).
3. Easypanel **Domains** tab → bind the new host to `site:8080`.
4. Redeploy. (Recreate the volume if the realtime tenant was seeded under the
   old name.)

---

## Local development

For local dev (with bind-mounts and live edits), use the other compose file:

```bash
docker compose up --build       # serves http://localhost:8080
```

That one uses `config/supabase.json` (localhost) and mounts `./selfhost/*`
scripts directly — handy for iterating, but **not** what Easypanel runs.
