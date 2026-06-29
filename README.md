# Hack Heroes 🦸

**Hack Heroes** is an open-source project designed to teach young learners about cybersecurity in a fun, interactive, and educational way. The ultimate aim is to inspire young people to consider cybersecurity and technology careers. The project offers in-browser cybersecurity challenges aimed at kids aged 8-14, but the engaging nature of the tasks makes it enjoyable for users of all ages.

## Features

- **Engaging Spy-Themed Cybersecurity Challenges**: Users are tasked with solving various missions that enhance their knowledge of technical concepts.
- **Interactive Learning**: Each challenge provides hints, objectives, and tools to help players complete tasks and learn along the way.
- **Alpine.js-Powered**: Application logic is built using [Alpine.js](https://alpinejs.dev/).
- **Customizable Toolset**: Challenges offer tools like an HTML Reader/Editor, JavaScript Console, Decoders and more to help users complete their missions.
- **Browser-Based**: All game logic executes in the user's browser making it easy to host and great for privacy and security
- **Local Data Storage**: Game progress is stored locally in the browser, making the game private and secure. 

## How to Play

1. Open [hackhero.es](https://hackhero.es/).
2. Select a challenge to start by clicking on a mission.
3. Read the mission briefing and review the available gadgets to help you solve the mission.
4. Once you think you've worked out the answer, enter it into the answer box and submit it to find out if you're right!

## Technologies Used

- **Bulma**: For a modern, responsive design.
- **Alpine.js**: For dynamic content rendering and interaction.
- **Ace Editor**: Integrated for users to read and edit HTML.
- **LocalStorage**: To store player progress within the browser.

## Classroom Mode (optional teacher layer)

Hack Heroes can optionally run in **classroom mode**, adding teacher accounts,
student groups, challenge assignments, and a **live leaderboard** — while
keeping the existing single-player game fully intact. If you don't configure it,
the site behaves exactly as before (local-only, anonymous play).

### What it adds

- **Teacher area** (`teacher.html`): register/sign in (email + password), create
  classes (each gets a friendly join code like `BRAVE-FOX-42`), and assign
  specific challenges to a class.
- **Student join** (`join.html?code=XYZ`): students join with a class code + a
  nickname only — **no email, no password, no personal data**.
- **Live leaderboard** (`dashboard.html?class=ID`): real-time standings showing
  who has completed which assigned challenges, who finished them **all first**
  (winner badge + confetti 🎉), hints used, and last activity.

### Architecture

- A [Supabase](https://supabase.com) backend (Postgres + Auth + Realtime)
  provides accounts, groups, assignments, and live progress. You can run it
  **fully self-hosted in Docker** (default — see
  [Running the whole thing in Docker](#running-the-whole-thing-in-docker-self-hosted-offline))
  or point at a **cloud Supabase** project.
- Each student's challenge state is still stored in their browser
  (`localStorage`) as the offline source of truth; progress is **mirrored** to
  the backend for the dashboard. This is wired in via a small
  `SyncingStorageHandler` that extends the existing `StorageHandler` — the
  challenge engine is untouched.
- The **anon key is public by design**; all access control is enforced
  server-side by Postgres Row Level Security (RLS). It is safe to commit
  `config/supabase.json`.

### Setup

**Fastest:** run the whole stack in Docker — `docker compose up --build`, then
open `teacher.html`. Everything (database, auth, realtime, schema) is configured
automatically. See
[Running the whole thing in Docker](#running-the-whole-thing-in-docker-self-hosted-offline).

**Cloud Supabase instead:**

1. Create a free Supabase project.
2. In **Authentication → Providers**, enable **Anonymous sign-ins** (used for
   students; no PII is collected).
3. In the **SQL Editor**, paste and run [`supabase/schema.sql`](supabase/schema.sql)
   (creates tables, the `join_class` RPC, RLS policies, and enables realtime).
4. Copy your project **URL** and **anon public key** (Project Settings → API) into
   [`config/supabase.json`](config/supabase.json).
5. Serve the site (locally: `python3 -m http.server 8000`) and open
   `teacher.html` to create your first class.

**Privacy note for educators:** students never provide an email, password, or
real name. Their identity is an anonymous, device-bound token plus a chosen
nickname. Clearing browser data or clicking "Leave class" removes the local
session.

## Running the whole thing in Docker (self-hosted, offline)

The entire stack — the site **and** the classroom backend — runs in containers
with **no cloud services and no internet required**. All front-end libraries are
vendored locally (`assets/vendor/`), and a self-hosted [Supabase](https://supabase.com)
stack (Postgres + Auth + REST + Realtime) provides the backend.

```bash
docker compose up --build      # start everything
# open http://localhost:8080

docker compose down            # stop (keeps the database volume)
docker compose down -v         # stop and wipe the database
```

That's it — `teacher.html`, `join.html`, `dashboard.html`, and the live
leaderboard all work out of the box, fully offline.

### What runs

| Service | Image | Role |
| --- | --- | --- |
| `db` | `supabase/postgres` | Postgres with Supabase roles/auth/realtime preinstalled |
| `db-setup` | `supabase/postgres` | One-shot: sets service-role passwords (runs as `supabase_admin`) |
| `auth` | `supabase/gotrue` | Teacher email+password **and** anonymous student sign-in |
| `rest` | `postgrest/postgrest` | The `/rest/v1` data API |
| `realtime` | `supabase/realtime` | Websocket changefeed powering the live leaderboard |
| `realtime-setup` | `alpine` | One-shot: registers the `localhost` Realtime tenant |
| `site` | built from `Dockerfile` | nginx — serves the site **and** reverse-proxies the backend |

The browser only ever talks to **one origin** (`http://localhost:8080`): nginx
serves the static files and proxies `/auth/v1`, `/rest/v1`, and `/realtime/v1`
to the Supabase services on the internal Docker network. No CORS, no exposed
database port.

### How the database is set up automatically

On a fresh volume, `docker compose up` does all of this with no manual steps:

1. `supabase/postgres` runs its own init (roles, `auth`/`realtime` schemas, extensions).
2. Our classroom schema ([`supabase/schema.sql`](supabase/schema.sql), mounted as
   an init file) auto-applies: tables, the `join_class` RPC, RLS policies, realtime.
3. `db-setup` sets the service-role passwords so `auth`/`rest`/`realtime` can connect.
4. `realtime-setup` registers the realtime tenant so live updates work.

### Configuration

All local-dev values live in [`.env`](.env) (committed so it works out of the
box) and [`config/supabase.json`](config/supabase.json), which points the
front-end at the local gateway. **These dev secrets are intentionally public —
do not reuse them for an internet-facing deployment.** `config/supabase.json` is
bind-mounted into the `site` container, so you can edit it and refresh the
browser without rebuilding.

> **Want cloud Supabase instead?** Set `url` + `anonKey` in
> `config/supabase.json` to your project's values, run
> [`supabase/schema.sql`](supabase/schema.sql) in the Supabase SQL editor, enable
> Anonymous sign-ins, and you can run just the `site` container on its own.

### Just the static game (no backend)

If you only want the single-player challenges (no classroom features), the
front-end is fully static and works with any web server, e.g.:

```bash
python3 -m http.server 8000      # then open http://localhost:8000
```

With no backend reachable, the classroom pages show a friendly "not configured"
message and the game plays exactly as before (local-only progress).

## Contributing

TBC

## Project Origin

This project was created by **Chris Cooper**, a cybersecurity professional and STEM ambassador from the UK.

## License

This project is open-source. The source code is licensed under GNU AGPLv3.

## Testing

This project is tested with BrowserStack.
