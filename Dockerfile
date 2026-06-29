# =====================================================================
# Hack Heroes — ROOT Dockerfile = ALL-IN-ONE single-container build.
#
# This is what Easypanel builds when you upload the repo (zip) as an App
# service: Postgres + GoTrue (auth) + PostgREST (rest) + nginx in ONE
# container, started by a bash supervisor, listening on :8080.
#
# Deploy on Easypanel:
#   1. + Service -> App
#   2. Source: Upload (the repo zip) -- or connect the GitHub repo.
#   3. Build: Dockerfile (this file, repo root). Build context = repo root.
#   4. Deploy. Then Domains tab -> add your host -> Port 8080 -> HTTPS.
#   5. Add a Volume mounted at /var/lib/postgresql/data to persist data.
#
# Live leaderboard uses a 4s POLLING fallback (dashboard.html), so it works
# without the Realtime service -- which avoids the Realtime/glibc mismatch
# (Realtime is a Debian-12/glibc-2.36 release; this base is Ubuntu 20.04).
#
# Build context is the REPO ROOT, so all COPY paths are repo-relative.
# =====================================================================

FROM supabase/gotrue:v2.151.0    AS gotrue
FROM postgrest/postgrest:v12.2.0 AS postgrest

FROM supabase/postgres:15.1.1.78

USER root

# nginx + curl + libpq5 (postgrest is dynamically linked).
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx curl ca-certificates libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

# GoTrue: static Go binary + its bundled migrations (applied from ./migrations
# relative to the CWD the supervisor uses: /usr/local/etc/auth).
COPY --from=gotrue /usr/local/bin/auth /usr/local/bin/auth
COPY --from=gotrue /usr/local/etc/auth /usr/local/etc/auth

# PostgREST: distroless image keeps the binary at /bin/postgrest.
COPY --from=postgrest /bin/postgrest /usr/local/bin/postgrest

# ---- web app (repo root) -> nginx html ----
COPY . /usr/share/nginx/html/
RUN cd /usr/share/nginx/html \
    && rm -rf .git .github allinone selfhost supabase node_modules \
              Dockerfile Dockerfile.site-only .dockerignore docker-compose.yml \
              docker-compose.easypanel.yml nginx.conf nginx.allinone.conf \
              hh-supervisor.sh hh-roles.sh DEPLOY-EASYPANEL.md \
              DEPLOY-EASYPANEL-APPS.md .env

# nginx gateway (all-in-one: upstreams are 127.0.0.1) + prod browser config.
COPY nginx.allinone.conf /etc/nginx/conf.d/hackheroes.conf
COPY config/supabase.prod.json /usr/share/nginx/html/config/supabase.json

# ---- DB init scripts (run by the official entrypoint on first boot) ----
COPY selfhost/zzz-hackheroes-schema.sql /docker-entrypoint-initdb.d/zzz-hackheroes-schema.sql
COPY hh-roles.sh                        /docker-entrypoint-initdb.d/zzz-zzz-roles.sh

# ---- supervisor ----
COPY hh-supervisor.sh /usr/local/bin/hh-supervisor.sh
RUN chmod +x /usr/local/bin/hh-supervisor.sh \
            /docker-entrypoint-initdb.d/zzz-zzz-roles.sh

# Persist the database (mount a volume here in Easypanel).
VOLUME ["/var/lib/postgresql/data"]

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/hh-supervisor.sh"]
