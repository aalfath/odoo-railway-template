#!/bin/bash
# Start script for Odoo on Railway (aalfath/odoo-railway-template).
#
# 1. Creates (or updates) a dedicated `odoo` Postgres role, because Odoo
#    refuses to run as the `postgres` superuser that Railway Postgres gives.
# 2. Writes /etc/odoo/odoo.conf: one database, database manager disabled,
#    master password from ODOO_MASTER_PASSWORD, proxy mode on, HTTP on $PORT.
# 3. On first start, creates and initialises the database with the admin
#    user `admin` and the password from ODOO_ADMIN_PASSWORD.
# 4. Runs Odoo as the unprivileged `odoo` user.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

log() { echo "[railway-start] $*"; }

: "${DATABASE_URL:?DATABASE_URL must point at the Postgres service (\${{Postgres.DATABASE_URL}})}"
: "${ODOO_MASTER_PASSWORD:?ODOO_MASTER_PASSWORD must be set}"
: "${ODOO_DB_PASSWORD:?ODOO_DB_PASSWORD must be set}"
: "${ODOO_ADMIN_PASSWORD:?ODOO_ADMIN_PASSWORD must be set}"

HTTP_PORT="${PORT:-8069}"
DB_NAME="${ODOO_DB_NAME:-odoo}"
DB_USER="${ODOO_DB_USER:-odoo}"
ADMIN_LOGIN="${ODOO_ADMIN_LOGIN:-admin}"
LANGUAGE="${ODOO_LANGUAGE:-en_US}"
DATA_DIR=/var/lib/odoo
CONF=/etc/odoo/odoo.conf

# Host and port of the Postgres server, read from DATABASE_URL.
read -r DB_HOST DB_PORT < <(python3 -c 'import os,urllib.parse as u; p=u.urlparse(os.environ["DATABASE_URL"]); print(p.hostname, p.port or 5432)')

log "waiting for Postgres at ${DB_HOST}:${DB_PORT}"
for i in $(seq 1 60); do
  if psql "$DATABASE_URL" -qtAc 'SELECT 1' >/dev/null 2>&1; then break; fi
  if [ "$i" = 60 ]; then log "Postgres did not answer in 120 s"; exit 1; fi
  sleep 2
done

log "ensuring database role ${DB_USER}"
psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -v u="$DB_USER" -v p="$ODOO_DB_PASSWORD" <<'SQL' >/dev/null
SELECT format('CREATE ROLE %I LOGIN CREATEDB', :'u')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN CREATEDB PASSWORD %L', :'u', :'p') \gexec
SQL

umask 077
cat > "$CONF" <<CONF
[options]
data_dir = ${DATA_DIR}
http_interface = 0.0.0.0
http_port = ${HTTP_PORT}
proxy_mode = True
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${ODOO_DB_PASSWORD}
db_name = ${DB_NAME}
dbfilter = ^${DB_NAME}\$
list_db = False
admin_passwd = ${ODOO_MASTER_PASSWORD}
workers = 0
CONF
chown odoo:odoo "$CONF"
chmod 600 "$CONF"

# Railway mounts volumes owned by root. Custom modules can go in
# /var/lib/odoo/addons/20.0, which is on the volume and in the addons path.
for d in "$DATA_DIR"; do
  mkdir -p "$d"
  [ "$(stat -c %U "$d")" = odoo ] || chown -R odoo:odoo "$d"
done

as_odoo() { runuser -u odoo -- env -i PATH="$PATH" HOME="$DATA_DIR" LANG=C.UTF-8 "$@"; }

db_state() {
  if [ -z "$(psql "$DATABASE_URL" -qtAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]; then
    echo missing
  elif [ -z "$(PGPASSWORD="$ODOO_DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -qtAc "SELECT 1 FROM pg_tables WHERE tablename = 'ir_module_module'")" ]; then
    echo empty
  else
    echo ready
  fi
}

state="$(db_state)"
if [ "$state" != ready ]; then
  log "first start: initialising database ${DB_NAME} (this takes a minute or two)"
  # Answer the health check while the database is being created.
  python3 - "$HTTP_PORT" <<'PY' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'Odoo is initialising its database. Reload in a minute.\n'
        self.send_response(200 if self.path.startswith('/web/health') else 503)
        self.send_header('Content-Type', 'text/plain'); self.send_header('Retry-After', '30')
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1])), H).serve_forever()
PY
  placeholder=$!
  force=()
  [ "$state" = empty ] && force=(--force)
  as_odoo odoo db -c "$CONF" init "${force[@]}" --language "$LANGUAGE" \
    --username "$ADMIN_LOGIN" --password "$ODOO_ADMIN_PASSWORD" "$DB_NAME"
  kill "$placeholder" 2>/dev/null || true
  wait "$placeholder" 2>/dev/null || true
  log "database ${DB_NAME} initialised; log in as '${ADMIN_LOGIN}' with ODOO_ADMIN_PASSWORD"
else
  log "database ${DB_NAME} already initialised"
fi

log "starting Odoo on port ${HTTP_PORT}"
exec runuser -u odoo -- env -i PATH="$PATH" HOME="$DATA_DIR" LANG=C.UTF-8 odoo -c "$CONF" "$@"
