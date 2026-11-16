# Odoo on Railway

Railway template for [Odoo](https://www.odoo.com/) Community Edition **20.0**, built from the official [`odoo`](https://hub.docker.com/_/odoo) Docker image, pinned by version and digest:

```
odoo:20.0-20261112@sha256:8bcae4c1f895683ee851e19dd3e7d999e81e770defe9015bc9dad8bbf10f2b0d
```

## What the template deploys

| Service | Source | Notes |
|---|---|---|
| **Odoo** | this repo (`Dockerfile`) | Public domain, health check `/web/health`, volume on `/var/lib/odoo` (filestore, sessions, extra modules) |
| **Postgres** | Railway Postgres | Odoo's database, reached over the private network |

On first start, `railway-start.sh`:

1. creates a dedicated `odoo` Postgres role (Odoo refuses to run as the `postgres` superuser),
2. writes `/etc/odoo/odoo.conf` with **one database (`odoo`)**, the **database manager disabled** (`list_db = False`), the master password (`admin_passwd`) from `ODOO_MASTER_PASSWORD`, and proxy mode on,
3. creates and initialises the `odoo` database with the admin user **`admin`** and the password from `ODOO_ADMIN_PASSWORD`, without demo data,
4. runs Odoo as the unprivileged `odoo` user on `$PORT`.

Later starts skip step 3. Odoo runs in threaded mode (`workers = 0`), so the web client, websockets and cron jobs share the one public port.

## Variables

| Variable | Default | What it is |
|---|---|---|
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Postgres superuser URL, used only at start to create the `odoo` role and database |
| `ODOO_ADMIN_PASSWORD` | generated secret | Password of the `admin` user created on first start. Changing it later has no effect: change the password in Odoo instead |
| `ODOO_MASTER_PASSWORD` | generated secret | Odoo's master password (`admin_passwd`) |
| `ODOO_DB_PASSWORD` | generated secret | Password of the `odoo` Postgres role (reset at every start) |
| `PORT` | `8069` | HTTP port Odoo listens on |

Optional, not in the template: `ODOO_LANGUAGE` (default `en_US`, first start only).

## First login

Open the service's public URL and log in with **`admin`** and the value of `ODOO_ADMIN_PASSWORD` (Railway → Odoo service → Variables). Then change the login to your email under the user's preferences, and install the apps you need (CRM, Sales, Invoicing, Inventory, …) from the Apps menu.

## Custom modules

Put extra modules in `/var/lib/odoo/addons/20.0` (on the volume, already in Odoo's addons path), or fork this repo and copy them into the image.

## Updates

Every change to this repo's `main` branch shows up as an "update available" notice for projects deployed from the template, and you choose when to apply it. Each update is listed in [CHANGELOG.md](CHANGELOG.md). Updates within 20.0 (newer nightly builds) need no migration. A move to a new Odoo major version needs a database migration (Odoo's upgrade service or OpenUpgrade) and will be called out as a breaking change.
