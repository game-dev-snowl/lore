#!/usr/bin/env bash
# Cold backup of the Lore stores: stop -> archive -> start.
# The local stores flush on a delay, so copying them while the server runs
# can capture an inconsistent snapshot. Expect ~1 minute of downtime per run.
#
#   sudo ./scripts/backup.sh [/backup/dir]       (default: /srv/lore/backups)
#
# Cron example (daily 04:15, keep 14):
#   15 4 * * * root /opt/lore/scripts/backup.sh >> /var/log/lore-backup.log 2>&1
set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$LORE_DIR/.env"; set +a
DATA_DIR="${LORE_DATA_DIR:?}"
BACKUP_DIR="${1:-/srv/lore/backups}"
KEEP="${KEEP:-14}"

mkdir -p "$BACKUP_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/lore-data-$stamp.tar.zst"

cd "$LORE_DIR"
echo "[$stamp] stopping loreserver"
docker compose stop loreserver
trap 'docker compose start loreserver' EXIT

tar -C "$DATA_DIR" --zstd -cf "$out" .
echo "wrote $out ($(du -h "$out" | cut -f1))"

ls -1t "$BACKUP_DIR"/lore-data-*.tar.zst | tail -n +"$((KEEP + 1))" | xargs -r rm -f
