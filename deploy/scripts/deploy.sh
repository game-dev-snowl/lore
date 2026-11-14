#!/usr/bin/env bash
# Update the Lore Server from the git clone it runs from (docs/GIT-DEPLOY.md),
# and roll back on its own if the server doesn't come back healthy.
#
#   ./scripts/deploy.sh                    # deploy what's new on origin/main
#   ./scripts/deploy.sh --version 0.14.0   # also move .env to a new image
#   ./scripts/deploy.sh --check            # show what would change, change nothing
#   ./scripts/deploy.sh --rollback         # go back to the last state before a deploy
#
# Run it as the user who owns the clone, or as root (a systemd timer): as root
# it runs git as that owner, so the clone never becomes root-owned.
#
# What it does, in order:
#   1. fetch origin, and list the commits and files under deploy/ that are new
#   2. fast-forward the clone, and set LORE_VERSION in .env if --version is given
#   3. check the Compose file resolves (`docker compose config`)
#   4. if the image changes: pull it while the old server runs, then take a
#      cold backup (scripts/backup.sh) before the new image starts
#   5. recreate the container (compose or .env change, new image) or restart it
#      (config/local.toml or certs change); scripts and docs need neither
#   6. wait until Docker reports the container healthy
#   7. on any failure after step 2: put the files back, start the old server
#      again, and remember the commit so an unattended run doesn't retry it
#
# It never touches the stores. If a new image changed the store format, going
# back to the old image needs the backup restored; the script prints how.
#
# Options:
#   -c, --check          print the plan and exit; nothing changes
#   -y, --yes            don't ask before applying (implied without a terminal)
#   -v, --version X.Y.Z  set LORE_VERSION in .env to this image tag
#   -b, --branch NAME    branch to deploy (default: main, or DEPLOY_BRANCH)
#       --force          recreate the container even if nothing changed (after
#                        a hand edit to .env), or retry a commit that failed
#       --no-backup      skip the backup before an image change
#       --no-rollback    leave a failed deploy in place, for debugging
#       --rollback       restore the commit and .env from before the last deploy
#   -h, --help           this text
#
# Environment: DEPLOY_BRANCH, HEALTH_TIMEOUT (seconds, default 180),
# BACKUP_DIR (passed to backup.sh, default /srv/lore/backups).
#
# Exit codes: 0 deployed or nothing to do, 1 failed and rolled back (or the
# rollback itself failed: read the output), 2 bad usage or preflight failure,
# 3 the target commit failed before and --force wasn't given.
set -euo pipefail
# The braces make bash read the whole script before running it: the deploy
# replaces this file with git, and bash otherwise reads a script as it goes.
{

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$LORE_DIR/.deploy"
CONTAINER=loreserver
SERVICE=loreserver

branch="${DEPLOY_BRANCH:-main}"
health_timeout="${HEALTH_TIMEOUT:-180}"
check=0 yes=0 force=0 backup=1 rollback_on_fail=1 do_rollback=0 new_version=""

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--check) check=1 ;;
    -y|--yes) yes=1 ;;
    -v|--version) [ $# -ge 2 ] || die "$1 needs a value"; new_version="$2"; shift ;;
    --version=*) new_version="${1#*=}" ;;
    -b|--branch) [ $# -ge 2 ] || die "$1 needs a value"; branch="$2"; shift ;;
    --branch=*) branch="${1#*=}" ;;
    --force) force=1 ;;
    --no-backup) backup=0 ;;
    --no-rollback) rollback_on_fail=0 ;;
    --rollback) do_rollback=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
  shift
done

if [ -n "$new_version" ] && ! printf '%s' "$new_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$'; then
  die "--version '$new_version' isn't an image tag like 0.14.0 (no leading v)"
fi
case "$health_timeout" in ''|*[!0-9]*) die "HEALTH_TIMEOUT must be a number of seconds" ;; esac
[ -t 0 ] || yes=1

# --- preflight -----------------------------------------------------------------

cd "$LORE_DIR"
command -v git >/dev/null || die "git isn't installed"
command -v docker >/dev/null || die "docker isn't installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin isn't installed, or this user can't reach docker (log out and in after setup-server.sh)"
[ -f .env ] || die "$LORE_DIR/.env is missing: copy .env.example and edit it first"

owner="$(stat -c %U "$LORE_DIR")"
owner_home="$(getent passwd "$owner" | cut -d: -f6)"
git_() {
  if [ "$(id -u)" -eq 0 ] && [ "$owner" != root ]; then
    runuser -u "$owner" -- env HOME="$owner_home" git -C "$LORE_DIR" "$@"
  else
    git -C "$LORE_DIR" "$@"
  fi
}

git_ rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "$LORE_DIR isn't a git clone. Move to the clone first: docs/GIT-DEPLOY.md, part B"
mkdir -p "$STATE_DIR"
# As root, create the state files owned by the clone's owner, so a later run
# as that user can still write them (writes to an existing file keep its owner).
if [ "$(id -u)" -eq 0 ]; then
  touch "$STATE_DIR"/{lock,history.log,failed}
  chown -R "$owner": "$STATE_DIR"
fi
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another deploy is running (lock: $STATE_DIR/lock)"

record() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE_DIR/history.log"; }

env_version() { sed -n 's/^LORE_VERSION=//p' .env | tail -n1; }
set_env_version() {
  if grep -q '^LORE_VERSION=' .env; then
    # Rewrite in place rather than sed -i, which would make a root run's .env root-owned.
    local t; t="$(sed "s/^LORE_VERSION=.*/LORE_VERSION=$1/" .env)"
    printf '%s\n' "$t" > .env
  else
    printf '\nLORE_VERSION=%s\n' "$1" >> .env
  fi
}
config_image() { docker compose config --images 2>/dev/null | head -n1; }
running_image() { docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true; }

# Healthy, and started after $1 (an RFC 3339 UTC time), so a status left over
# from the container we replaced doesn't count.
wait_healthy() {
  local since="$1" deadline=$((SECONDS + health_timeout)) status started restarts base
  base="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo 0)"
  log "waiting up to ${health_timeout}s for $CONTAINER to report healthy"
  while [ "$SECONDS" -lt "$deadline" ]; do
    read -r status started restarts < <(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} {{.State.StartedAt}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo "missing 0 0")
    if [ "$status" = healthy ] && [[ "$started" > "$since" ]]; then
      log "$CONTAINER is healthy"
      return 0
    fi
    # The health check takes 90 s to call a crashing server unhealthy; a
    # restart loop says so sooner.
    if [ "$((restarts - base))" -ge 2 ]; then
      status="crash-looping"
      break
    fi
    sleep 3
  done
  log "$CONTAINER is $status. Last log lines:"
  docker compose logs --tail 15 "$SERVICE" 2>&1 | sed 's/^/    /' || true
  return 1
}

now() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }

# Saved before any change, read by --rollback and by the automatic rollback.
save_state() {
  cp -p .env "$STATE_DIR/env.before"
  printf 'rev=%s\nimage=%s\ntime=%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/before"
}

# Put the clone and .env back to $1 and the saved .env, and start the server.
restore() {
  local rev="$1" t
  log "rolling back to ${rev:0:12} and the saved .env"
  git_ reset --hard -q "$rev"
  cp -p "$STATE_DIR/env.before" .env
  t="$(now)"
  # Force: a config/local.toml change leaves the definition as it was, and
  # up -d alone would keep the container that read the bad config.
  docker compose up -d --force-recreate "$SERVICE"
  wait_healthy "$t"
}

# --- rollback mode -------------------------------------------------------------

if [ "$do_rollback" -eq 1 ]; then
  [ -f "$STATE_DIR/before" ] && [ -f "$STATE_DIR/env.before" ] || die "no earlier deploy recorded in $STATE_DIR"
  prev_rev="$(sed -n 's/^rev=//p' "$STATE_DIR/before")"
  prev_image="$(sed -n 's/^image=//p' "$STATE_DIR/before")"
  log "last deploy started from ${prev_rev:0:12} running $prev_image"
  if [ "$check" -eq 1 ]; then exit 0; fi
  if [ "$yes" -eq 0 ]; then
    read -r -p "Roll back to that? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || exit 0
  fi
  cur_rev="$(git_ rev-parse HEAD)"
  restore "$prev_rev" || die "the rolled-back server isn't healthy: docker compose logs $SERVICE" 1
  # Don't let an unattended run deploy the commit we just left again.
  [ "$cur_rev" != "$prev_rev" ] && echo "$cur_rev" >> "$STATE_DIR/failed"
  record "rollback ${cur_rev:0:12} -> ${prev_rev:0:12} image=$(config_image)"
  log "rolled back. If the newer image changed the store format, restore the backup taken before it:"
  log "  docker compose stop $SERVICE && sudo tar -C <LORE_DATA_DIR> --zstd -xf <backup>.tar.zst && docker compose start $SERVICE   (docs/DEPLOYMENT.md, Backups)"
  exit 0
fi

# --- plan ----------------------------------------------------------------------

if ! git_ diff --quiet HEAD; then
  git_ status --short
  die "tracked files were changed on the server. Move the change to the repository, then 'git checkout -- <file>' (docs/GIT-DEPLOY.md, Troubleshooting)"
fi
cur_branch="$(git_ symbolic-ref --short -q HEAD || echo DETACHED)"
[ "$cur_branch" = "$branch" ] || die "the clone is on '$cur_branch', not '$branch': git switch $branch"

log "fetching origin/$branch"
git_ fetch -q origin "$branch"
old_rev="$(git_ rev-parse HEAD)"
new_rev="$(git_ rev-parse FETCH_HEAD)"
git_ merge-base --is-ancestor "$old_rev" "$new_rev" ||
  die "origin/$branch doesn't contain the deployed commit ${old_rev:0:12} (history was rewritten?). Resolve by hand"

old_image="$(config_image)"
run_image="$(running_image)"
[ -n "$old_image" ] || die "docker compose config fails on the current files: run it to see why"

changed=()
# --relative: paths under deploy/, relative to it, e.g. config/local.toml.
[ "$old_rev" != "$new_rev" ] && mapfile -t changed < <(git_ diff --name-only --relative "$old_rev" "$new_rev")

if [ "$old_rev" != "$new_rev" ] && [ -f "$STATE_DIR/failed" ] && grep -qx "$new_rev" "$STATE_DIR/failed" && [ "$force" -eq 0 ]; then
  die "${new_rev:0:12} failed to deploy before. Push a fix, or run with --force to try it again" 3
fi

version_change=0
if [ -n "$new_version" ] && [ "$new_version" != "$(env_version)" ]; then version_change=1; fi
drift=0
if [ -n "$run_image" ] && [ "$run_image" != "$old_image" ]; then drift=1; fi

if [ "${#changed[@]}" -eq 0 ] && [ "$version_change" -eq 0 ] && [ "$drift" -eq 0 ] && [ "$force" -eq 0 ]; then
  if [ "$old_rev" != "$new_rev" ]; then
    # Commits outside deploy/ only: move the clone along, nothing to restart.
    [ "$check" -eq 1 ] || git_ merge --ff-only -q "$new_rev"
    log "new commits outside deploy/ only; clone moved to ${new_rev:0:12}, server untouched"
  else
    log "up to date at ${old_rev:0:12}, running $run_image"
  fi
  exit 0
fi

echo
echo "  clone:   ${old_rev:0:12} -> ${new_rev:0:12} ($branch)"
if [ "$old_rev" != "$new_rev" ]; then
  git_ log --oneline --no-decorate --relative "$old_rev..$new_rev" -- . | sed 's/^/             /'
  echo "  files:"
  printf '             %s\n' "${changed[@]}"
fi
[ "$version_change" -eq 1 ] && echo "  .env:    LORE_VERSION $(env_version) -> $new_version"
[ "$drift" -eq 1 ] && echo "  running: $run_image, but the files say $old_image (edited .env?)"
echo
if [ "$version_change" -eq 1 ]; then
  echo "  Read the release notes for $new_version before you go on: config keys and the"
  echo "  store format can change. https://github.com/EpicGames/lore/releases"
  echo
fi

if [ "$check" -eq 1 ]; then log "--check: nothing changed"; exit 0; fi
if [ "$yes" -eq 0 ]; then
  read -r -p "Apply? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || { log "nothing changed"; exit 0; }
fi

# --- apply ---------------------------------------------------------------------

save_state "$old_rev" "${run_image:-$old_image}"
applied=0
# shellcheck disable=SC2329 # run by the EXIT trap
on_failure() {
  local rc=$?
  [ "$applied" -eq 1 ] || exit "$rc"
  trap - EXIT
  [ "$old_rev" != "$new_rev" ] && echo "$new_rev" >> "$STATE_DIR/failed"
  record "FAILED ${old_rev:0:12} -> ${new_rev:0:12} version=${new_version:-unchanged}"
  if [ "$rollback_on_fail" -eq 0 ]; then
    log "deploy failed; left in place (--no-rollback). Undo with: $0 --rollback"
    exit 1
  fi
  if restore "$old_rev"; then
    log "deploy failed and was rolled back; the server runs the old version again"
  else
    log "deploy failed AND the rollback isn't healthy: docker compose logs $SERVICE"
  fi
  exit 1
}
trap on_failure EXIT
applied=1

[ "$old_rev" != "$new_rev" ] && git_ merge --ff-only -q "$new_rev"
[ "$version_change" -eq 1 ] && set_env_version "$new_version"

log "checking the Compose configuration"
docker compose config -q
new_image="$(config_image)"

recreate=0 restart=0
if [ "$new_image" != "${run_image:-}" ]; then
  recreate=1
  log "pulling $new_image (the old server keeps running)"
  docker compose pull --quiet "$SERVICE"
  if [ "$backup" -eq 1 ] && [ -n "$run_image" ]; then
    log "image changes ($run_image -> $new_image): taking a cold backup first"
    if [ "$(id -u)" -eq 0 ]; then
      "$LORE_DIR/scripts/backup.sh" ${BACKUP_DIR:+"$BACKUP_DIR"}
    else
      sudo "$LORE_DIR/scripts/backup.sh" ${BACKUP_DIR:+"$BACKUP_DIR"}
    fi
  fi
fi
for f in "${changed[@]}"; do
  case "$f" in
    docker-compose.yml) recreate=1 ;;
    config/*|certs/*) restart=1 ;;
  esac
done
# --force: a fresh container, so a hand edit to .env (ports, paths) applies too.
[ "$force" -eq 1 ] && recreate=1 restart=1

t="$(now)"
if [ "$recreate" -eq 1 ]; then
  log "recreating $SERVICE"
  if [ "$restart" -eq 1 ]; then
    # The definition may be unchanged, and up -d would then keep the container.
    docker compose up -d --force-recreate "$SERVICE"
  else
    docker compose up -d "$SERVICE"
  fi
  wait_healthy "$t"
elif [ "$restart" -eq 1 ]; then
  log "restarting $SERVICE for the config change"
  docker compose restart "$SERVICE"
  wait_healthy "$t"
else
  log "only scripts or docs changed; the server keeps running"
fi

trap - EXIT
record "ok ${old_rev:0:12} -> ${new_rev:0:12} image=$new_image"
log "deployed ${new_rev:0:12}, running $new_image"
docker compose ps "$SERVICE"
exit 0
}
