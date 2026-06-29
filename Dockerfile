# Hack Heroes — static site container
#
# This serves the static Hack Heroes site (and the optional classroom layer)
# with nginx. The site is pure HTML/JS/CSS with all libraries loaded from CDNs,
# so the image is tiny and needs no build step.
#
# Build:  docker build -t hackheroes .
# Run:    docker run --rm -p 8080:8080 hackheroes
# Open:   http://localhost:8080
#
# To use the classroom features, edit config/supabase.json (or mount your own
# at runtime, see README / docker-compose.yml).

FROM nginx:1.27-alpine

# Run nginx as the unprivileged built-in user on a non-privileged port (8080).
# nginx:alpine already ships an "nginx" user; we just point everything at 8080.
RUN rm /etc/nginx/conf.d/default.conf

# Site content
COPY . /usr/share/nginx/html

# Our server config
COPY nginx.conf /etc/nginx/conf.d/hackheroes.conf

# Drop files that shouldn't be web-served (defence in depth; .dockerignore
# already excludes most). Keep config/, challenges/, assets/.
RUN rm -f /usr/share/nginx/html/Dockerfile \
          /usr/share/nginx/html/.dockerignore \
          /usr/share/nginx/html/docker-compose.yml \
          /usr/share/nginx/html/nginx.conf

EXPOSE 8080

# Healthcheck hits the homepage on the IPv4 loopback explicitly (the busybox
# wget in nginx:alpine can fail to resolve "localhost" inside the container).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
