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

# A deploy (scripts/deploy.sh) restarts the server, so the two never overlap:
# wait for a running deploy. deploy.sh sets LORE_DEPLOY_LOCK_HELD when it runs
# this script itself, holding the lock already.
if [ -z "${LORE_DEPLOY_LOCK_HELD:-}" ]; then
  lock="${LORE_LOCK_FILE:-/run/lock/lore-deploy.lock}"
  [ -d "$(dirname "$lock")" ] || lock="$LORE_DIR/.deploy/lock"
  mkdir -p "$(dirname "$lock")"
  [ -e "$lock" ] || { touch "$lock" && chmod 0644 "$lock"; }
  exec 9<"$lock"
  flock -w 3600 9 || { echo "a deploy has held $lock for an hour; no backup taken" >&2; exit 1; }
fi

mkdir -p "$BACKUP_DIR"
# Left by a run that was killed before it finished.
rm -f "$BACKUP_DIR"/lore-data-*.tar.zst.partial
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/lore-data-$stamp.tar.zst"

cd "$LORE_DIR"
echo "[$stamp] stopping loreserver"
docker compose stop loreserver
trap 'docker compose start loreserver' EXIT

# Written under another name and renamed when complete, so a failed run
# leaves no archive that looks whole and isn't.
tar -C "$DATA_DIR" --zstd -cf "$out.partial" . || { rm -f "$out.partial"; exit 1; }
mv "$out.partial" "$out"
echo "wrote $out ($(du -h "$out" | cut -f1))"

ls -1t "$BACKUP_DIR"/lore-data-*.tar.zst | tail -n +"$((KEEP + 1))" | xargs -r rm -f
