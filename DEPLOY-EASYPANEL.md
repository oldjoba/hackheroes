# Deploying Hack Heroes on Easypanel — single container (upload or repo)

The **entire stack runs in ONE container**: Postgres + Auth (GoTrue) +
Data API (PostgREST) + nginx. You deploy it as **one Easypanel App service**
that builds the repo's root `Dockerfile`. Map your domain to port **8080** and
you're done.

This is the simplest, most reliable path — no compose, no multiple services,
no container registry, no networking gotchas.

> Live leaderboard updates via a 4-second polling fallback (no separate
> Realtime service needed), so the dashboard still updates "live" (~4s).

---

## Step 1 — Get the code into Easypanel

**Option A — Upload the zip**
1. On GitHub: `oldjoba/hackheroes` → **Code ▾ → Download ZIP**.
2. Easypanel → your project → **+ Service → App** → name it `hackheroes`.
3. **Source: Upload** → upload the zip.

**Option B — Connect the repo**
1. Easypanel → **+ Service → App** → name `hackheroes`.
2. **Source: GitHub** → repo `oldjoba/hackheroes`, branch `main`.

Either way, **Build = Dockerfile**, **Dockerfile path = `Dockerfile`** (root),
**Build context = `/`** (defaults are correct).

---

## Step 2 — Add a volume (persist the database)

App service → **Mounts / Volumes** → add a **Volume**:
- **Mount path:** `/var/lib/postgresql/data`

Without this, classes/students/progress reset on every redeploy.

---

## Step 3 — Deploy

Click **Deploy**. The build pulls the auth/rest base images and compiles the
all-in-one image, then boots. First boot runs DB init (schema + role passwords)
and GoTrue's migrations. In the logs you'll see:

```
[hh-supervisor] Postgres is accepting connections.
[hh-supervisor] service roles ready.
[hh-supervisor] legacy auth tables cleared.
[hh-supervisor] starting GoTrue (auth) on :9999…
[hh-supervisor] starting PostgREST (rest) on :3000…
[hh-supervisor] starting nginx on :8080 (foreground)…
[hh-supervisor] all services launched.
```

---

## Step 4 — Map the domain

App service → **Domains** tab → **Add**:
- **Host:** `heroes.beonflow.de`
- **Port:** `8080`
- **HTTPS:** on (free Let's Encrypt cert via Traefik)

Open **https://heroes.beonflow.de** — the game loads. The browser only talks to
this one origin; nginx inside the container proxies `/auth/v1` and `/rest/v1` to
the in-container services.

---

## Step 5 — Verify the classroom

1. `https://heroes.beonflow.de/teacher.html` → **register** (email + password)
   → create a class → assign a couple of challenges.
2. Open the class **Leaderboard** (`dashboard.html?class=...`).
3. Incognito → **join link** (`join.html?code=YOUR-CODE`) → nickname → solve a
   challenge → the dashboard updates within ~4s.

Verified end-to-end before release: teacher signup → teacher row → class →
assignment → anonymous student join → progress completion → dashboard read.

---

## Troubleshooting

**Build fails**
- Make sure the build uses the **root `Dockerfile`** with context `/` (defaults).
- It's a multi-stage build pulling `supabase/gotrue`, `postgrest/postgrest`,
  `supabase/postgres` — give the first build a few minutes.

**Page won't open / 502**
- Domain must bind to **port 8080** (that's what nginx listens on).
- Check the App logs: you should see `all services launched.` If Postgres is
  still initializing on first boot, wait a minute and refresh.

**Teacher signup error**
- Should be fixed in this build (GoTrue now migrates the full `auth` schema and
  the RLS policies are intact). If you see it, check the logs for a Postgres
  `ERROR` line and share it.

**Reset everything**
- Delete the App's volume (`/var/lib/postgresql/data`) and redeploy. Schema,
  role passwords, and auth migrations re-run on the fresh volume.

---

## Security note

The secrets baked into the image (JWT secret, DB password, anon/service keys)
are **shared demo values** (also in this public repo). Fine for a classroom
demo behind Postgres RLS. To harden, regenerate `JWT_SECRET` + the matching
anon/service JWTs (`config/supabase.prod.json` `anonKey`) + `POSTGRES_PASSWORD`,
and pass them as env vars on the App service (the supervisor reads
`POSTGRES_PASSWORD`, `JWT_SECRET`, `PUBLIC_URL`).

---

## Changing the domain

Set the new host in **`config/supabase.prod.json`** (`url`) and redeploy
(rebuilds with the new baked config). Also set the App env var `PUBLIC_URL` to
the new origin, and bind the new host to port 8080 in the Domains tab.

---

## Other deploy options (advanced)

- **Multiple services / Compose:** `docker-compose.easypanel.yml` and
  `DEPLOY-EASYPANEL-APPS.md` describe a separated-services setup (with a real
  Realtime service for instant push). The single-container path above is
  recommended for simplicity.
- **Local dev:** `docker compose up --build` serves `http://localhost:8080`
  using the separated stack.
