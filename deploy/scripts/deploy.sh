#!/usr/bin/env bash
# Update the Lore Server from the git clone it runs from (docs/GIT-DEPLOY.md),
# and roll back on its own if the server doesn't come back healthy.
# docs/UPDATING.md is the guide.
#
#   ./scripts/deploy.sh                    # deploy what's new on origin/main
#   ./scripts/deploy.sh --version 0.14.0   # also move .env to a new image
#   ./scripts/deploy.sh --check            # show what would change, change nothing
#   ./scripts/deploy.sh --rollback         # back to the state before the last deploy
#
# Run it as the user who owns the clone, or as root (a systemd timer): as root
# it runs git as that owner, so the clone never becomes root-owned.
#
# What it does, in order:
#   1. fetch origin, and print the commits and files under deploy/ that are
#      new and what the deploy will do with them
#   2. fast-forward the clone, and set LORE_VERSION in .env if --version is given
#   3. check the Compose file resolves (`docker compose config`)
#   4. if the image changes: pull it while the old server runs, then take a
#      cold backup (scripts/backup.sh) before the new image starts
#   5. recreate the container (compose file or image change) or restart it
#      (config/ or certs/ change); scripts and docs need neither
#   6. wait until Docker reports the container healthy
#   7. on a failure in 2-6: put the files back, and if the server was touched,
#      start it again from the last healthy state. A commit whose Compose file
#      doesn't resolve, or whose server doesn't come up, is remembered so an
#      unattended run doesn't retry it.
#
# It never changes the stores. If a new image changed the store format, going
# back to the old image needs the backup restored: docs/UPDATING.md, Rolling back.
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
#       --rollback       return to the healthy state before the last deploy
#                        that restarted the server
#   -h, --help           this text
#
# Environment: DEPLOY_BRANCH, HEALTH_TIMEOUT (seconds, default 180),
# BACKUP_DIR (passed to backup.sh, default /srv/lore/backups), LORE_LOCK_FILE
# (default /run/lock/lore-deploy.lock; tests point it elsewhere).
#
# Exit codes:
#   0  deployed, or nothing to do
#   1  the deploy failed; the files are back as they were, and the server too
#      if it was touched (the output says if that rollback failed as well)
#   2  refused or failed before changing anything
#   3  the target commit failed before; push a fix, or pass --force
#   4  another deploy or a backup holds the lock
set -euo pipefail
# The braces make bash read the whole script before running it: the deploy
# replaces this file with git, and bash otherwise reads a script as it goes.
{

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$LORE_DIR/.deploy"
# Shared with scripts/backup.sh, so a deploy and a backup never overlap.
LOCK_FILE="${LORE_LOCK_FILE:-/run/lock/lore-deploy.lock}"
[ -d "$(dirname "$LOCK_FILE")" ] || LOCK_FILE="$STATE_DIR/lock"
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
is_root=0
[ "$(id -u)" -eq 0 ] && is_root=1
# 9<&-: git doesn't inherit the lock, which a detached `git gc --auto` would
# otherwise hold after this script exits.
git_() {
  if [ "$is_root" -eq 1 ] && [ "$owner" != root ]; then
    runuser -u "$owner" -- env HOME="$owner_home" git -C "$LORE_DIR" "$@" 9<&-
  else
    git -C "$LORE_DIR" "$@" 9<&-
  fi
}

if [ "$is_root" -eq 0 ] && [ "$(id -un)" != "$owner" ]; then
  die "run this as $owner, who owns $LORE_DIR, or as root"
fi
git_ rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "$LORE_DIR isn't a git clone. Move to the clone first: docs/GIT-DEPLOY.md, part B"

mkdir -p "$STATE_DIR"
# phase: plan (nothing changed yet), apply, finished. The EXIT handler maps an
# unexpected failure in the plan phase to exit 2, and keeps the state files
# owned by the clone's owner after a root run.
phase=plan
# Every exit goes through here, from either EXIT trap.
# shellcheck disable=SC2329 # called from the EXIT traps
finish() {
  if [ "$is_root" -eq 1 ]; then chown -R "$owner": "$STATE_DIR" 2>/dev/null || true; fi
  exit "$1"
}
# shellcheck disable=SC2329 # run by the EXIT trap
on_exit() {
  local rc=$?
  if [ "$phase" = plan ] && { [ "$rc" -eq 1 ] || [ "$rc" -gt 4 ]; }; then rc=2; fi
  finish "$rc"
}
trap on_exit EXIT

# Opened read-only: flock needs no write access, so a lock file root created
# serves the owner too, and the reverse.
[ -e "$LOCK_FILE" ] || { touch "$LOCK_FILE" && chmod 0644 "$LOCK_FILE"; } 2>/dev/null || true
exec 9<"$LOCK_FILE"
flock -n 9 || die "another deploy or a backup is running (lock: $LOCK_FILE)" 4

record() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE_DIR/history.log"; }

env_version() { sed -n 's/^LORE_VERSION=//p' .env | tail -n1 | tr -d "\"'"; }
set_env_version() {
  if grep -q '^LORE_VERSION=' .env; then
    # Rewrite in place rather than sed -i, which would make a root run's .env root-owned.
    local t; t="$(sed "s/^LORE_VERSION=.*/LORE_VERSION=$1/" .env)"
    printf '%s\n' "$t" > .env
  else
    printf '\nLORE_VERSION=%s\n' "$1" >> .env
  fi
}
config_image() { docker compose config --images 2>/dev/null | head -n1 || true; }
running_image() { docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true; }
started_at() { docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || echo none; }

# Healthy, in a container started after $1 (its StartedAt before the action),
# so the status of the container we replaced doesn't count.
wait_healthy() {
  local before="$1" deadline=$((SECONDS + health_timeout)) status started restarts base
  base="$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo 0)"
  log "waiting up to ${health_timeout}s for $CONTAINER to report healthy"
  while [ "$SECONDS" -lt "$deadline" ]; do
    read -r status started restarts < <(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} {{.State.StartedAt}} {{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo "missing none 0")
    if [ "$status" = healthy ] && [ "$started" != "$before" ]; then
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

# A healthy state: .deploy/<name> holds rev= and image=, .deploy/<name>.env the .env.
# backup= names the archive taken just before this state started, if any.
save_state() { # name rev image env-file [backup]
  cp -p "$4" "$STATE_DIR/$1.env"
  printf 'rev=%s\nimage=%s\nbackup=%s\ntime=%s\n' "$2" "$3" "${5:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/$1"
}
state_field() { sed -n "s/^$2=//p" "$STATE_DIR/$1"; }

# Put the files back to commit $1 and .env file $2. Called from `if`, where
# set -e is off, so each step checks its own result.
reset_files() {
  git_ reset --hard -q "$1" || return 1
  cp -p "$2" .env || return 1
}
# reset_files, then start a fresh container from them and wait for it.
restore() {
  local t
  log "restoring ${1:0:12} and its .env"
  reset_files "$1" "$2" || return 1
  t="$(started_at)"
  # Force: a config/ change leaves the definition as it was, and up -d alone
  # would keep the container that read the bad config.
  docker compose up -d --force-recreate "$SERVICE" || return 1
  wait_healthy "$t"
}

restore_advice() { # from-image to-image [backup-archive]
  log "The image changed from $1 to $2. If the newer one changed the store format,"
  log "the older one needs the backup taken before the upgrade: docs/UPDATING.md, Rolling back."
  if [ -n "${3:-}" ]; then log "That backup is $3."; fi
}

# --- rollback mode -------------------------------------------------------------

if [ "$do_rollback" -eq 1 ]; then
  if ! git_ diff --quiet HEAD; then
    git_ status --short
    die "tracked files were changed on the server; a rollback would discard them. Move the change to the repository first"
  fi
  # After a failed deploy left in place (--no-rollback), the state to return
  # to is the last healthy one, good; otherwise the one before it, prev.
  target=prev
  [ -f "$STATE_DIR/pending" ] && target=good
  [ -f "$STATE_DIR/$target" ] && [ -f "$STATE_DIR/$target.env" ] ||
    die "no earlier healthy state recorded in $STATE_DIR (it's kept after a deploy that restarts the server)"
  to_rev="$(state_field "$target" rev)"
  to_image="$(state_field "$target" image)"
  # The archive taken before the state we leave started.
  from_backup=""
  if [ "$target" = prev ]; then from_backup="$(state_field good backup 2>/dev/null || true)"; fi
  cur_rev="$(git_ rev-parse HEAD)"
  cur_image="$(running_image)"
  log "back to ${to_rev:0:12} running $to_image (now ${cur_rev:0:12} running $cur_image)"
  [ "$check" -eq 1 ] && exit 0
  if [ "$yes" -eq 0 ]; then
    read -r -p "Roll back? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || exit 0
  fi
  phase=apply
  if ! restore "$to_rev" "$STATE_DIR/$target.env"; then
    if [ "$cur_image" != "$to_image" ]; then restore_advice "$cur_image" "$to_image" "$from_backup"; fi
    die "the rolled-back server isn't healthy: docker compose logs $SERVICE" 1
  fi
  phase=finished
  # Don't let an unattended run deploy the commit we just left again.
  if [ "$cur_rev" != "$to_rev" ]; then echo "$cur_rev" >> "$STATE_DIR/failed"; fi
  if [ "$target" = prev ]; then
    mv "$STATE_DIR/prev" "$STATE_DIR/good"
    mv "$STATE_DIR/prev.env" "$STATE_DIR/good.env"
  fi
  rm -f "$STATE_DIR/pending"
  record "rollback ${cur_rev:0:12} -> ${to_rev:0:12} image=$to_image"
  log "rolled back"
  if [ "$cur_image" != "$to_image" ]; then restore_advice "$cur_image" "$to_image" "$from_backup"; fi
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
git_ fetch -q origin "$branch" || die "git fetch failed; nothing changed"
old_rev="$(git_ rev-parse HEAD)"
new_rev="$(git_ rev-parse FETCH_HEAD)"
git_ merge-base --is-ancestor "$old_rev" "$new_rev" ||
  die "origin/$branch doesn't contain the deployed commit ${old_rev:0:12} (history was rewritten?). Resolve by hand"

old_image="$(config_image)"
run_image="$(running_image)"
[ -n "$old_image" ] || die "docker compose config fails on the current files: run it to see why"

changed=()
# --relative: paths under deploy/, relative to it, e.g. config/local.toml.
# --no-renames: a rename lists its old path too, so a moved config file counts.
if [ "$old_rev" != "$new_rev" ]; then
  mapfile -t changed < <(git_ diff --name-only --no-renames --relative "$old_rev" "$new_rev")
fi

if [ "$old_rev" != "$new_rev" ] && [ -f "$STATE_DIR/failed" ] && grep -qx "$new_rev" "$STATE_DIR/failed" && [ "$force" -eq 0 ]; then
  [ "$check" -eq 1 ] || die "${new_rev:0:12} failed to deploy before. Push a fix, or run with --force to try it again" 3
  log "${new_rev:0:12} failed to deploy before; a deploy needs --force"
fi

version_change=0
if [ -n "$new_version" ] && [ "$new_version" != "$(env_version)" ]; then version_change=1; fi
drift=0
if [ -n "$run_image" ] && [ "$run_image" != "$old_image" ]; then drift=1; fi

if [ "${#changed[@]}" -eq 0 ] && [ "$version_change" -eq 0 ] && [ "$drift" -eq 0 ] && [ "$force" -eq 0 ]; then
  if [ "$old_rev" != "$new_rev" ]; then
    # Commits outside deploy/ only: move the clone along, nothing to restart.
    if [ "$check" -eq 0 ]; then
      git_ merge --ff-only -q "$new_rev" || die "git merge failed; nothing changed"
    fi
    log "new commits outside deploy/ only; clone at ${new_rev:0:12}, server untouched"
  else
    log "up to date at ${old_rev:0:12}, running $run_image"
  fi
  exit 0
fi

# What the deploy will do. The image comes from the new compose file and
# .env (with --version applied) before either is changed.
decide() { # image-to-run
  recreate=0 restart=0
  [ "$1" != "$run_image" ] && recreate=1
  local f
  for f in "${changed[@]}"; do
    case "$f" in
      docker-compose.yml) recreate=1 ;;
      config/*|certs/*) restart=1 ;;
    esac
  done
  # --force: a fresh container, so a hand edit to .env (ports, paths) applies too.
  if [ "$force" -eq 1 ]; then recreate=1 restart=1; fi
}
plan_image="$old_image"
if [ "$old_rev" != "$new_rev" ] || [ "$version_change" -eq 1 ]; then
  tmp_compose="$STATE_DIR/compose.next.yml"
  git_ show "$new_rev:./docker-compose.yml" > "$tmp_compose"
  plan_image="$(
    [ "$version_change" -eq 1 ] && export LORE_VERSION="$new_version"
    docker compose -f "$tmp_compose" --project-directory "$LORE_DIR" config --images 2>/dev/null | head -n1 || true
  )"
  rm -f "$tmp_compose"
  [ -n "$plan_image" ] || plan_image="(the new compose file doesn't resolve)"
fi
decide "$plan_image"

echo
echo "  clone:   ${old_rev:0:12} -> ${new_rev:0:12} ($branch)"
if [ "$old_rev" != "$new_rev" ]; then
  git_ log --oneline --no-decorate --relative "$old_rev..$new_rev" -- . | sed 's/^/             /'
  echo "  files:"
  printf '             %s\n' "${changed[@]}"
fi
[ "$version_change" -eq 1 ] && echo "  .env:    LORE_VERSION $(env_version) -> $new_version"
[ "$drift" -eq 1 ] && echo "  running: $run_image, but the files say $old_image (edited .env?)"
if [ "$plan_image" != "$run_image" ]; then
  if [ "$backup" -eq 1 ] && [ -n "$run_image" ]; then
    echo "  action:  pull $plan_image, back up the stores (~1 min down), recreate"
  else
    echo "  action:  pull $plan_image, recreate"
  fi
elif [ "$recreate" -eq 1 ]; then echo "  action:  recreate the container (~10 s down)"
elif [ "$restart" -eq 1 ]; then echo "  action:  restart the server (~10 s down)"
else echo "  action:  none; the server keeps running"
fi
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

cp -p .env "$STATE_DIR/before.env"
rm -f "$STATE_DIR/failed.env" "$STATE_DIR/pending"
# Where a failure that touched the server goes back to: the last healthy
# state's .env if there is one, so a bad hand edit to .env isn't restored
# along with the commit. A failure that didn't touch it puts .env back as it was.
back_env="$STATE_DIR/before.env"
[ -f "$STATE_DIR/good.env" ] && back_env="$STATE_DIR/good.env"
touched=0   # the server was stopped, restarted or recreated
blame=0     # the failure is the commit's: remember it in .deploy/failed
new_image=""
backup_file=""

# shellcheck disable=SC2329 # run by the EXIT trap
on_failure() {
  local to_image
  if [ "$blame" -eq 1 ] && [ "$old_rev" != "$new_rev" ]; then echo "$new_rev" >> "$STATE_DIR/failed"; fi
  record "FAILED ${old_rev:0:12} -> ${new_rev:0:12} version=${new_version:-unchanged} touched=$touched"
  if [ "$rollback_on_fail" -eq 0 ]; then
    # Tells --rollback to return to good, the state this deploy replaced.
    echo "$new_rev" > "$STATE_DIR/pending"
    log "deploy failed; left in place (--no-rollback). Undo with: $0 --rollback"
    finish 1
  fi
  if [ "$touched" -eq 0 ]; then
    if reset_files "$old_rev" "$STATE_DIR/before.env"; then
      log "deploy failed before the server was touched; files put back, server unchanged"
    else
      log "deploy failed, and putting the files back failed too: check git status and .env"
    fi
    finish 1
  fi
  cmp -s .env "$back_env" || cp -p .env "$STATE_DIR/failed.env"
  if restore "$old_rev" "$back_env"; then
    log "deploy failed and was rolled back; the server runs the last healthy state"
  else
    log "deploy failed AND the rollback isn't healthy: docker compose logs $SERVICE"
  fi
  # The image the rollback started may differ from the one the deploy tried,
  # whether or not the rollback came up: the stores may need the backup.
  to_image="$(config_image)"
  tried="${new_image:-$run_image}"
  if [ -n "$tried" ] && [ "$tried" != "$to_image" ]; then restore_advice "$tried" "$to_image" "$backup_file"; fi
  if [ -f "$STATE_DIR/failed.env" ]; then
    log "the .env this deploy tried is kept in $STATE_DIR/failed.env"
  fi
  finish 1
}
phase=apply
trap on_failure EXIT

if [ "$old_rev" != "$new_rev" ]; then git_ merge --ff-only -q "$new_rev"; fi
[ "$version_change" -eq 1 ] && set_env_version "$new_version"

log "checking the Compose configuration"
blame=1
docker compose config -q
new_image="$(config_image)"
blame=0
decide "$new_image"

if [ "$new_image" != "$run_image" ]; then
  log "pulling $new_image (the old server keeps running)"
  docker compose pull --quiet "$SERVICE"
  if [ "$backup" -eq 1 ] && [ -n "$run_image" ]; then
    log "image changes ($run_image -> $new_image): taking a cold backup first"
    touched=1
    # --lock-held: this run holds the lock backup.sh would wait for. An
    # argument, not a variable, since sudo drops variables without SETENV.
    if [ "$is_root" -eq 1 ]; then
      "$LORE_DIR/scripts/backup.sh" --lock-held ${BACKUP_DIR:+"$BACKUP_DIR"} | tee "$STATE_DIR/backup.out"
    else
      sudo "$LORE_DIR/scripts/backup.sh" --lock-held ${BACKUP_DIR:+"$BACKUP_DIR"} | tee "$STATE_DIR/backup.out"
    fi
    backup_file="$(sed -n 's/^wrote \(.*\) (.*)$/\1/p' "$STATE_DIR/backup.out" | tail -n1)"
    rm -f "$STATE_DIR/backup.out"
  fi
fi

blame=1
t="$(started_at)"
if [ "$recreate" -eq 1 ]; then
  log "recreating $SERVICE"
  touched=1
  # Force: up -d keeps the container when the definition is unchanged, as
  # after a comment-only edit or a config/ change, and the health wait
  # needs a container that started now.
  docker compose up -d --force-recreate "$SERVICE"
  wait_healthy "$t"
elif [ "$restart" -eq 1 ]; then
  log "restarting $SERVICE for the config change"
  touched=1
  docker compose restart "$SERVICE"
  wait_healthy "$t"
else
  log "only scripts or docs changed; the server keeps running"
fi

phase=finished
trap on_exit EXIT
# The rollback point moves only when the running server changed, so a later
# docs-only deploy doesn't hide the state before an upgrade.
# Without a restart, .env wasn't tested, so good keeps its .env and only
# moves to the new commit.
if [ "$touched" -eq 1 ]; then
  if [ -f "$STATE_DIR/good" ]; then
    mv "$STATE_DIR/good" "$STATE_DIR/prev"
    mv "$STATE_DIR/good.env" "$STATE_DIR/prev.env"
  else
    save_state prev "$old_rev" "${run_image:-$old_image}" "$STATE_DIR/before.env"
  fi
  save_state good "$new_rev" "$new_image" .env "$backup_file"
elif [ -f "$STATE_DIR/good" ]; then
  t="$(sed "s/^rev=.*/rev=$new_rev/" "$STATE_DIR/good")"
  printf '%s\n' "$t" > "$STATE_DIR/good"
else
  save_state good "$new_rev" "$new_image" .env
fi
record "ok ${old_rev:0:12} -> ${new_rev:0:12} image=$new_image${backup_file:+ backup=$backup_file}"
log "deployed ${new_rev:0:12}, running $new_image"
docker compose ps "$SERVICE"
exit 0
}
