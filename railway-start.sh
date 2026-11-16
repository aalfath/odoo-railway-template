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

# missing: no database yet. empty: the database exists but base never finished
# installing (an interrupted first start). ready: anything else. A connection
# error makes the script exit instead of guessing.
db_state() {
  python3 - "$DB_NAME" <<'PY'
import os, sys, psycopg2
url, name = os.environ["DATABASE_URL"], sys.argv[1]
with psycopg2.connect(url) as c, c.cursor() as cur:
    cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,))
    if not cur.fetchone():
        print("missing"); sys.exit()
with psycopg2.connect(url, dbname=name) as c, c.cursor() as cur:
    cur.execute("SELECT to_regclass('public.ir_module_module') IS NOT NULL")
    if not cur.fetchone()[0]:
        print("empty"); sys.exit()
    cur.execute("SELECT state FROM ir_module_module WHERE name = 'base'")
    row = cur.fetchone()
    print("ready" if row and row[0] in ("installed", "to upgrade", "to remove") else "empty")
PY
}

# First start: create and initialise the database. A Postgres advisory lock
# makes concurrent starts (two deployments overlapping) take turns, so one
# never drops a database the other is still initialising.
init_db() {
  local state force=()
  state="$(db_state)"
  if [ "$state" = ready ]; then
    log "database ${DB_NAME} was initialised by another start"
    return
  fi
  log "first start: initialising database ${DB_NAME} (this takes a minute or two)"
  [ "$state" = empty ] && force=(--force)
  as_odoo odoo db -c "$CONF" init "${force[@]}" --language "$LANGUAGE" \
    --username "$ADMIN_LOGIN" --password "$ODOO_ADMIN_PASSWORD" "$DB_NAME"
  log "database ${DB_NAME} initialised; log in as '${ADMIN_LOGIN}' with ODOO_ADMIN_PASSWORD"
}

if [ "${1:-}" = --init-locked ]; then
  init_db
  exit 0
fi

state="$(db_state)"
if [ "$state" != ready ]; then
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
  python3 - "$0" --init-locked <<'PY'
import os, sys, subprocess, psycopg2
conn = psycopg2.connect(os.environ["DATABASE_URL"])
conn.autocommit = True
conn.cursor().execute("SELECT pg_advisory_lock(hashtext('odoo-railway-template-init'))")
sys.exit(subprocess.call(sys.argv[1:]))
PY
  kill "$placeholder" 2>/dev/null || true
  wait "$placeholder" 2>/dev/null || true
else
  log "database ${DB_NAME} already initialised"
fi

log "starting Odoo on port ${HTTP_PORT}"
exec runuser -u odoo -- env -i PATH="$PATH" HOME="$DATA_DIR" LANG=C.UTF-8 odoo -c "$CONF" "$@"
