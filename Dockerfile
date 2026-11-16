# Odoo Community, official image, pinned by version and digest.
# To update: bump the tag and digest here and add a CHANGELOG.md entry.
FROM odoo:20.0-20261112@sha256:8bcae4c1f895683ee851e19dd3e7d999e81e770defe9015bc9dad8bbf10f2b0d

# The start script runs as root only to fix the volume's ownership and
# to write the config file, then runs Odoo as the image's `odoo` user.
USER root
COPY railway-start.sh /usr/local/bin/railway-start.sh
RUN chmod 755 /usr/local/bin/railway-start.sh

EXPOSE 8069
ENTRYPOINT ["/usr/local/bin/railway-start.sh"]
