#!/usr/bin/env bash
# certbot --deploy-hook: copy the renewed cert into $LORE_DIR/certs as real
# files (the container can't follow /etc/letsencrypt symlinks) and restart
# loreserver, which only reads its certificate at startup.
#
# certbot provides RENEWED_LINEAGE; LORE_DIR is baked into the hook command
# by issue-cert.sh.
set -euo pipefail

: "${RENEWED_LINEAGE:?not called by certbot}"
: "${LORE_DIR:?LORE_DIR not set}"

dest="$LORE_DIR/certs"
install -d -m 0750 "$dest"
install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$dest/fullchain.pem"
install -m 0600 "$RENEWED_LINEAGE/privkey.pem"   "$dest/privkey.pem"

cd "$LORE_DIR"
if docker compose ps --status running --services 2>/dev/null | grep -qx loreserver; then
  docker compose restart loreserver
  logger -t lore-cert "certificate renewed, loreserver restarted"
else
  logger -t lore-cert "certificate installed; loreserver not running, no restart"
fi
