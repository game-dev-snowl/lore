#!/usr/bin/env bash
# Tests for scripts/deploy.sh and scripts/backup.sh. Real git, a stub docker.
#
#   ./tests/test-deploy.sh
#
# Each case builds an origin repository holding a copy of deploy/, clones it,
# and runs deploy.sh in the clone with tests/stubs first on PATH. The docker
# stub keeps the container's state in files and logs each call, so a case
# asserts which compose commands ran; the sudo and runuser stubs run their
# command as the caller, so the suite runs as any user. Needs git, bash,
# flock, tar and zstd; no Docker.
#
# Not covered: real Docker and Compose (restart and health semantics), and
# file ownership after a root run; check those by hand on a test host.
# shellcheck disable=SC2016,SC2034 # checks are strings run by eval, which reads these
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SRC="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HEALTH_TIMEOUT=10
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -f "$out" ] && sed 's/^/        | /' "$out"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A fresh origin, clone and stub state; the server runs 0.13.0, healthy.
setup() {
  rm -rf "$WORK/case"; mkdir -p "$WORK/case"
  C="$WORK/case"
  mkdir -p "$C/src"
  cp -a "$DEPLOY_SRC" "$C/src/deploy"
  rm -rf "$C/src/deploy/.env" "$C/src/deploy/.deploy" "$C/src/deploy/data" "$C/src/deploy/backups"
  git -C "$C/src" init -q -b main
  git -C "$C/src" add -A
  git -C "$C/src" commit -qm base
  git clone -q --bare "$C/src" "$C/origin.git"
  git -C "$C/src" remote add origin "$C/origin.git"
  git clone -q "$C/origin.git" "$C/clone"
  D="$C/clone/deploy"
  mkdir -p "$C/data" "$C/backups"
  echo store > "$C/data/blob"
  cat > "$D/.env" <<EOF
LORE_VERSION=0.13.0
LORE_DATA_DIR=$C/data
EOF
  export STUB_DIR="$C/stub" BACKUP_DIR="$C/backups" LORE_LOCK_FILE="$C/lock"
  mkdir -p "$STUB_DIR"
  echo "ghcr.io/epicgames/lore/loreserver:0.13.0" > "$STUB_DIR/image"
  echo 1 > "$STUB_DIR/started"
  out="$C/out"
}
# Commit a change made by "$@" in the origin's working copy and push it.
push() {
  local msg="$1"; shift
  (cd "$C/src/deploy" && "$@")
  git -C "$C/src" add -A
  git -C "$C/src" commit -qm "$msg"
  git -C "$C/src" push -q origin main
}
deploy() { # args...; sets rc, output in $out
  rc=0
  (cd "$D" && PATH="$HERE/stubs:$PATH" ./scripts/deploy.sh "$@") </dev/null >"$out" 2>&1 || rc=$?
}
# The calls that act on the container, without the read-only ones.
calls() { grep -v -E '^inspect|^compose( -f [^ ]+| --project-directory [^ ]+)* (version|config|logs|ps)' "$STUB_DIR/calls" 2>/dev/null | tr '\n' ';' || true; }
reset_calls() { : > "$STUB_DIR/calls"; }
rev() { git -C "$C/clone" rev-parse HEAD; }
origin_rev() { git -C "$C/src" rev-parse HEAD; }

echo "deploy.sh"

setup
deploy
check "nothing new: exit 0, no compose command" '[ $rc -eq 0 ] && [ -z "$(calls)" ] && grep -q "up to date" "$out"'

setup
push docs bash -c 'echo more >> docs/UPDATING.md'
deploy
check "docs change: fast-forwards, no restart" '[ $rc -eq 0 ] && [ "$(rev)" = "$(origin_rev)" ] && [ -z "$(calls)" ]'

setup
push outside bash -c 'echo x > ../OUTSIDE.md'
deploy
check "commit outside deploy/: clone moves, server untouched" '[ $rc -eq 0 ] && [ "$(rev)" = "$(origin_rev)" ] && [ -z "$(calls)" ]'

setup
push config sed -i 's/flush_delay_seconds = 10/flush_delay_seconds = 5/' config/local.toml
deploy --check
check "--check prints the restart and changes nothing" '[ $rc -eq 0 ] && grep -q "action:  restart" "$out" && [ "$(rev)" != "$(origin_rev)" ] && [ -z "$(calls)" ]'
deploy
check "config change: restart only" '[ $rc -eq 0 ] && [ "$(calls)" = "compose restart loreserver;" ]'

setup
push rename git mv config/local.toml config/moved.toml
deploy
check "renamed config file: restart" '[ $rc -eq 0 ] && [ "$(calls)" = "compose restart loreserver;" ]'

setup
push compose sed -i 's/max-file: "5"/max-file: "6"/' docker-compose.yml
deploy
check "compose change: recreate" '[ $rc -eq 0 ] && [ "$(calls)" = "compose up -d --force-recreate loreserver;" ]'

setup
push crash bash -c 'echo "# STUB_CRASH" >> config/local.toml'
bad_rev="$(origin_rev)"
deploy
check "server that won't start: exit 1, files and server rolled back" '[ $rc -eq 1 ] && [ "$(rev)" != "$bad_rev" ] && ! grep -q STUB_CRASH "$D/config/local.toml" && [ "$(calls)" = "compose restart loreserver;compose up -d --force-recreate loreserver;" ]'
check "  ... and the commit is remembered" 'grep -qx "$bad_rev" "$D/.deploy/failed"'
deploy
check "  ... the next run refuses it with exit 3" '[ $rc -eq 3 ]'
push fix bash -c 'sed -i "/STUB_CRASH/d" config/local.toml'
deploy
check "  ... a fix on top deploys" '[ $rc -eq 0 ] && [ "$(rev)" = "$(origin_rev)" ]'

setup
push broken-compose bash -c 'echo "# STUB_BROKEN" >> docker-compose.yml'
deploy
check "compose file that doesn't resolve: server untouched, commit remembered" '[ $rc -eq 1 ] && [ -z "$(calls)" ] && grep -q "server unchanged" "$out" && [ -s "$D/.deploy/failed" ]'

setup
deploy --version 0.13.9-missing
check "missing image: .env restored, server untouched, nothing remembered" '[ $rc -eq 1 ] && grep -qx LORE_VERSION=0.13.0 "$D/.env" && [ "$(calls)" = "compose pull --quiet loreserver;" ] && [ ! -s "$D/.deploy/failed" ]'

setup
deploy --version 0.14.0 --check
check "--version --check names the new image and the backup" '[ $rc -eq 0 ] && grep -q "pull ghcr.io/epicgames/lore/loreserver:0.14.0, back up" "$out" && [ -z "$(calls)" ]'
deploy --version 0.14.0
check "--version: pull, backup, recreate" '[ $rc -eq 0 ] && [ "$(calls)" = "compose pull --quiet loreserver;compose stop loreserver;compose start loreserver;compose up -d --force-recreate loreserver;" ] && ls "$C/backups"/lore-data-*.tar.zst >/dev/null'
check "  ... .env holds the new version" 'grep -qx LORE_VERSION=0.14.0 "$D/.env"'
push docs bash -c 'echo more >> docs/UPDATING.md'
deploy
reset_calls
deploy --rollback
check "--rollback after an upgrade and a docs deploy: back to 0.13.0" '[ $rc -eq 0 ] && grep -qx LORE_VERSION=0.13.0 "$D/.env" && [ "$(cat "$STUB_DIR/image")" = ghcr.io/epicgames/lore/loreserver:0.13.0 ] && grep -q "store format" "$out"'

setup
deploy --rollback
check "--rollback with no earlier state: exit 2" '[ $rc -eq 2 ]'

setup
sed -i 's/^LORE_VERSION=.*/LORE_VERSION=0.13.0-bad/' "$D/.env"
cp "$D/.env" "$C/bad.env"
sed -i 's/^LORE_VERSION=.*/LORE_VERSION=0.13.0/' "$D/.env"
push config sed -i 's/flush_delay_seconds = 10/flush_delay_seconds = 5/' config/local.toml
deploy
push crash bash -c 'echo "# STUB_CRASH" >> config/local.toml'
cp "$C/bad.env" "$D/.env"
deploy
check "failure after a hand edit to .env: restores the last healthy .env" '[ $rc -eq 1 ] && grep -qx LORE_VERSION=0.13.0 "$D/.env" && [ -f "$D/.deploy/failed.env" ]'

setup
echo "# edited" >> "$D/docker-compose.yml"
deploy
check "tracked file edited on the server: exit 2" '[ $rc -eq 2 ] && grep -q "changed on the server" "$out"'

setup
push compose sed -i 's/max-file: "5"/max-file: "6"/' docker-compose.yml
touch "$LORE_LOCK_FILE"
exec 8<"$LORE_LOCK_FILE"
flock 8
deploy
flock -u 8
check "lock held: exit 4, nothing changed" '[ $rc -eq 4 ] && [ "$(rev)" != "$(origin_rev)" ]'

setup
mv "$D/.env" "$D/env.saved"
deploy
check "no .env: exit 2" '[ $rc -eq 2 ]'

setup
push compose-comment bash -c 'sed -i "1s/^/# a comment\n/" docker-compose.yml'
deploy
check "comment-only compose change: recreated and healthy" '[ $rc -eq 0 ] && [ "$(calls)" = "compose up -d --force-recreate loreserver;" ]'

setup
push config sed -i 's/flush_delay_seconds = 10/flush_delay_seconds = 5/' config/local.toml
deploy
good_rev="$(rev)"
push crash bash -c 'echo "# STUB_CRASH" >> config/local.toml'
deploy --no-rollback
check "--no-rollback leaves the failure in place" '[ $rc -eq 1 ] && grep -q STUB_CRASH "$D/config/local.toml"'
deploy --rollback
check "  ... then --rollback returns to the state it replaced" '[ $rc -eq 0 ] && [ "$(rev)" = "$good_rev" ] && [ ! -f "$D/.deploy/pending" ]'

setup
sed -i 's/^LORE_VERSION=.*/LORE_VERSION=0.14.0/' "$D/.env"
deploy
check "hand-edited LORE_VERSION (drift): pull, backup, recreate" '[ $rc -eq 0 ] && [ "$(cat "$STUB_DIR/image")" = ghcr.io/epicgames/lore/loreserver:0.14.0 ] && ls "$C/backups"/lore-data-*.tar.zst >/dev/null'

setup
deploy --force
check "--force alone: recreates" '[ $rc -eq 0 ] && [ "$(calls)" = "compose up -d --force-recreate loreserver;" ]'

setup
mkdir -p "$C/badtar"
printf '#!/bin/sh\nexit 1\n' > "$C/badtar/tar"; chmod +x "$C/badtar/tar"
rc=0; (cd "$D" && PATH="$C/badtar:$HERE/stubs:$PATH" ./scripts/deploy.sh --version 0.14.0) </dev/null >"$out" 2>&1 || rc=$?
check "backup fails during an upgrade: exit 1, old image back, nothing remembered" '[ $rc -eq 1 ] && grep -qx LORE_VERSION=0.13.0 "$D/.env" && [ "$(cat "$STUB_DIR/image")" = ghcr.io/epicgames/lore/loreserver:0.13.0 ] && [ ! -s "$D/.deploy/failed" ]'

setup
deploy --version 0.14.0-crash
check "upgrade whose server won't start: back to 0.13.0, names the backup" '[ $rc -eq 1 ] && [ "$(cat "$STUB_DIR/image")" = ghcr.io/epicgames/lore/loreserver:0.13.0 ] && grep -q "store format" "$out" && grep -q "That backup is $C/backups/lore-data-" "$out"'

setup
push config sed -i 's/flush_delay_seconds = 10/flush_delay_seconds = 5/' config/local.toml
deploy
echo "RUST_LOG=bogus" >> "$D/.env"
push docs bash -c 'echo more >> docs/UPDATING.md'
deploy
push crash bash -c 'echo "# STUB_CRASH" >> config/local.toml'
deploy
check "hand edit to .env, docs deploy, failure: restores the .env from before the edit" '[ $rc -eq 1 ] && ! grep -q RUST_LOG=bogus "$D/.env"'

setup
push crash bash -c 'echo "# STUB_CRASH" >> config/local.toml'
deploy
deploy --check
check "--check on a commit that failed before: shows the plan, exit 0" '[ $rc -eq 0 ] && grep -q "needs --force" "$out" && grep -q "action:" "$out"'

echo "backup.sh"

setup
mkdir -p "$C/badtar"
cat > "$C/badtar/tar" <<'EOF'
#!/bin/sh
# Writes part of the archive named after -cf, then fails.
while [ $# -gt 0 ]; do [ "$1" = -cf ] && { echo partial > "$2"; }; shift; done
exit 1
EOF
chmod +x "$C/badtar/tar"
rc=0; (cd "$D" && PATH="$C/badtar:$HERE/stubs:$PATH" ./scripts/backup.sh "$C/backups") >"$out" 2>&1 || rc=$?
check "failed tar: exit non-zero, no archive left, server started again" '[ $rc -ne 0 ] && [ -z "$(ls "$C/backups")" ] && tail -n1 "$STUB_DIR/calls" | grep -q "compose start"'

setup
echo stale > "$C/backups/lore-data-20000101T000000Z.tar.zst.partial"
rc=0; (cd "$D" && PATH="$HERE/stubs:$PATH" ./scripts/backup.sh "$C/backups") >"$out" 2>&1 || rc=$?
check "a run removes partials a killed run left" '[ $rc -eq 0 ] && ! ls "$C/backups"/*.partial >/dev/null 2>&1 && ls "$C/backups"/lore-data-*.tar.zst >/dev/null'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
