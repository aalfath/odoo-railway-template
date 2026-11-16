# Changelog

## 2026-11-16: Deploy on Railway button

- README: added the Deploy on Railway button for the published template (`odoo-2`). No change to the app or the image.

## 2026-11-16: Odoo 20.0 (build 20261112)

- First release of the template: Odoo Community 20.0 from `odoo:20.0-20261112@sha256:8bcae4c1f895683ee851e19dd3e7d999e81e770defe9015bc9dad8bbf10f2b0d`, with Railway Postgres.
- First start creates a dedicated `odoo` Postgres role and initialises the `odoo` database with the `admin` user and a generated password.
- Database manager disabled (`list_db = False`), master password from a generated secret.
- Filestore on a volume at `/var/lib/odoo`.
