#!/usr/bin/env bash
# Cold backup of the Lore stores: stop -> archive -> start.
# The local stores flush on a delay, so copying them while the server runs
# can capture an inconsistent snapshot. Expect ~1 minute of downtime per run.
#
#   sudo ./scripts/backup.sh [--lock-held] [/backup/dir]   (default: /srv/lore/backups)
#
# --lock-held: the caller (scripts/deploy.sh) holds the deploy lock already.
#
# Cron example (daily 04:15, keep 14):
#   15 4 * * * root /opt/lore/scripts/backup.sh >> /var/log/lore-backup.log 2>&1
set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_held=0
if [ "${1:-}" = --lock-held ]; then lock_held=1; shift; fi
set -a; . "$LORE_DIR/.env"; set +a
DATA_DIR="${LORE_DATA_DIR:?}"
BACKUP_DIR="${1:-/srv/lore/backups}"
KEEP="${KEEP:-14}"

# A deploy (scripts/deploy.sh) restarts the server, so the two never overlap:
# wait for a running deploy.
if [ "$lock_held" -eq 0 ]; then
  lock="${LORE_LOCK_FILE:-/run/lock/lore-deploy.lock}"
  if [ ! -d "$(dirname "$lock")" ]; then
    lock="$LORE_DIR/.deploy/lock"
    # Owned like the clone, so the owner's deploys can still write their state.
    mkdir -p "$LORE_DIR/.deploy" && chown --reference="$LORE_DIR" "$LORE_DIR/.deploy"
  fi
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
