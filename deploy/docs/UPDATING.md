# Updating the server

How to roll out changes to the Lore Server: this update, every later one, and how to run updates unattended. All of it goes through `scripts/deploy.sh`, which runs on the server, in the git clone from [GIT-DEPLOY.md](GIT-DEPLOY.md).

There are two kinds of change, and they reach the server by different routes:

| Change | Where it comes from | How it reaches the server |
|---|---|---|
| Deployment files: `docker-compose.yml`, `config/local.toml`, `scripts/`, docs | this repository, `deploy/` on `main` | `./scripts/deploy.sh` (a `git pull` that restarts what it must) |
| The Lore Server program itself | an official image, `ghcr.io/epicgames/lore/loreserver:<version>` | `./scripts/deploy.sh --version <version>` (sets `LORE_VERSION` in `.env`) |

Server code merged into this fork from EpicGames/lore reaches the server only in an official image. In November 2026, for example, the composite store's round-robin read replicas were on `main` (workspace version `0.13.1-nightly`) while the newest image was `0.13.0`. That code reaches the server when Epic publishes the next release and you move to it with `--version`. Building your own image from the nightly source is possible (`lore-server/Dockerfile`), but this guide doesn't cover it: it would run unreleased code against your stores.

## What deploy.sh does

```text
fetch origin/main ─▶ show plan  ─▶ fast-forward clone ─▶ docker compose config
                     (--check stops here)
                                  (+ set LORE_VERSION)          │
                                                                ▼
                              image changes? ── yes ─▶ pull image (old server still up)
                                    │                  cold backup (scripts/backup.sh)
                                    no                          │
                                    ▼                           ▼
              compose changed? ─▶ recreate      config/certs changed? ─▶ restart
              scripts/docs only ─▶ nothing to restart
                                                                │
                                                                ▼
                                  wait for "healthy" ── fails ─▶ put files back, start the last
                                                                 healthy state, remember the commit
```

| Changed file | Action | Downtime |
|---|---|---|
| `scripts/*`, `docs/*`, `auth0/*`, anything outside `deploy/` | none | none |
| `config/local.toml`, `certs/*` | `docker compose restart` | ~5–10 s |
| `docker-compose.yml` | `docker compose up -d --force-recreate` | ~5–10 s |
| image (`--version`, or a different image in the files) | pull, backup, recreate | ~1 min backup + ~10 s |

Safety rails:

- It refuses to run while a tracked file is edited on the server, while another deploy or a backup runs (they share a lock, `/run/lock/lore-deploy.lock`), or when `origin/main` doesn't contain the deployed commit.
- It waits until Docker reports the container healthy, and gives up early if the server is crash-looping (a bad `local.toml` fails in about 10 s).
- On failure it rolls back on its own. A failure before the server is touched (a merge, a pull, a Compose file that doesn't resolve) only puts the files back; the server keeps running. A fetch that fails stops the run before anything changes. A failure after it starts a fresh container from the previous commit and the last healthy `.env`.
- A commit whose Compose file doesn't resolve, or whose server doesn't come up, goes into `.deploy/failed`, so an unattended run won't try it again until a newer commit lands, or you pass `--force`. A network or registry error doesn't: the next run tries again.
- If a rollback doesn't come up healthy either, later runs exit 3 rather than deploy over a server that's down, until a `--force` deploy or a `--rollback` succeeds. A scripts-only deploy also fails while the server is unhealthy, since nothing would check it.
- On its first run it records the running server as the healthy state to go back to, so a later hand edit to `.env` that fails can be undone.
- It never changes the stores. If a new image changed the store format, going back to the old image needs the backup restored ([Rolling back](#rolling-back)).

## Part 1: the first update with deploy.sh

Do this once, for the rollout that brings `deploy.sh` to the server.

### 1. Make sure the server runs from the git clone

On the server:

```bash
git -C /opt/lore/deploy rev-parse HEAD 2>/dev/null && echo "git clone: OK" || echo "rsync copy: do GIT-DEPLOY.md part B first"
```

If it says rsync copy, follow [GIT-DEPLOY.md, part B](GIT-DEPLOY.md#b-replace-an-existing-rsync-copy). It takes a backup, moves `/opt/lore` aside, clones, and brings `.env` and the certificates across. Work in `/opt/lore/deploy` from then on.

### 2. Get deploy.sh onto the server

`deploy.sh` arrives with the change that adds it. Merge that pull request to `main`, then once, by hand:

```bash
cd /opt/lore/deploy
git pull --ff-only
ls scripts/deploy.sh
```

From now on `deploy.sh` does the pull itself.

### 3. See what's pending

```bash
./scripts/deploy.sh --check
```

It lists the commits and files under `deploy/` that the server doesn't have yet, and on the `action:` line what the deploy will do: none, restart, recreate, or pull, back up and recreate. Nothing changes. After the `git pull` in step 2 this usually says `up to date`.

### 4. Deploy

```bash
./scripts/deploy.sh
```

It shows the plan, asks `Apply? [y/N]`, and finishes with `deployed <commit>, running <image>` and the container status, which should end in `(healthy)`. Check it from a client too:

```bash
lore repository list lores://<LORE_DOMAIN>:41337
```

### 5. Check the image version

Compare `grep LORE_VERSION .env` with the newest release at <https://github.com/EpicGames/lore/releases>. If a newer one exists, follow [Upgrading the Lore image](#upgrading-the-lore-image). Then set up the timer, if you want one: [Part 3](#part-3-automating-it).

## Part 2: every later update

### Changing the deployment files

1. Change the file in the repository, on your machine or on GitHub. Never on the server: `deploy.sh` refuses to run over an edit to a tracked file.
2. Open a pull request and merge it to `main`.
3. On the server: `cd /opt/lore/deploy && ./scripts/deploy.sh`, or let the timer do it ([Part 3](#part-3-automating-it)).

Host-local values (domain, bind addresses, data directory, image version) live in `.env`, which isn't in git. After editing `.env` by hand, run `./scripts/deploy.sh --force` so the container picks it up and is health-checked. Run `deploy.sh` at least once before the first hand edit: that run records the running server as the state a failure goes back to. Without one, a deploy refuses to apply an edited image version unless you pass `--force`.

### Upgrading the Lore image

1. Read the release notes for the new version: <https://github.com/EpicGames/lore/releases> and `docs/release-notes.md` in this repository. Look for *Breaking changes* that touch `lore-server` or a config key in `config/local.toml`. If a key changed, change `config/local.toml` in the repository and merge that first, or in the same pull request.
2. Check the image exists: `docker manifest inspect ghcr.io/epicgames/lore/loreserver:<version> >/dev/null && echo ok`.
3. On the server:

   ```bash
   cd /opt/lore/deploy
   ./scripts/deploy.sh --version <version>      # e.g. 0.14.0, no leading v
   ```

   It pulls the image while the old server keeps running, takes a cold backup (about a minute of downtime), then starts the new image. With `sudo` it may ask for your password, for the backup.
4. Check from a client: `lore repository list`, and clone or sync a repository.
5. Update your client CLIs to the same version: [install-lore-cli.md](../../docs/how-to/install-lore-cli.md).

`.env.example` keeps the version as documentation only. The version that runs is `LORE_VERSION` in `.env`. To keep it in git instead, see [Option B](#option-b-the-image-version-in-git).

### Rolling back

To go back to the healthy state before the last deploy that restarted or recreated the server:

```bash
./scripts/deploy.sh --rollback
```

It restores that state's commit and `.env` and starts a fresh container from them. Deploys that touch only scripts or docs don't move this point, so `--rollback` after an upgrade and a later docs-only deploy still returns to the old version. After a failed deploy left in place with `--no-rollback`, it returns to the healthy state that deploy replaced instead. It goes back one step: it doesn't keep a history of states.

If the deploy you're undoing changed the image, and the new version changed the store format, the old image may not read the stores any more. The script says so whenever a rollback changes the image, and names the backup taken before the upgrade. Use that archive, not the newest one: a nightly backup taken after the upgrade holds the new format. `history.log` names it too (`backup=` on the upgrade's line), and `backup.sh` keeps only the newest 14 archives, so copy it aside if the rollback can wait.

Restore it with the timer stopped, so no deploy starts the server on a half-restored store. With `LORE_DATA_DIR` from `.env`:

```bash
sudo systemctl stop lore-deploy.timer          # if you set it up
docker compose stop loreserver
sudo sh -c 'find <LORE_DATA_DIR> -mindepth 1 -delete && tar -C <LORE_DATA_DIR> --zstd -xf <the archive named above>'
docker compose start loreserver
sudo systemctl start lore-deploy.timer
```

This loses every push made since the backup.

To undo a change for good, revert the commit on `main` and deploy. `--rollback` marks the commit it leaves as failed, so the timer won't deploy it again, but any newer commit on `main` brings the change back with it.

### Reference

```text
./scripts/deploy.sh [--check] [--yes] [--version X.Y.Z] [--branch NAME]
                    [--force] [--no-backup] [--no-rollback] [--rollback]
```

| Option | Meaning |
|---|---|
| `--check` | show the plan and the action it leads to, change nothing |
| `--yes` | don't ask; implied when there's no terminal (timer, cron, CI) |
| `--version X.Y.Z` | set `LORE_VERSION` in `.env` |
| `--branch NAME` | deploy another branch (default `main`); the clone must be on it |
| `--force` | recreate the container even when nothing changed (after a hand edit to `.env`), or retry a failed commit |
| `--no-backup` | skip the backup before an image change |
| `--no-rollback` | leave a failed deploy running, to debug it; undo with `--rollback` |
| `--rollback` | return to the healthy state before the last deploy that restarted the server |

Environment: `HEALTH_TIMEOUT` (default 180 s), `BACKUP_DIR` (default `/srv/lore/backups`), `DEPLOY_BRANCH`, `LORE_LOCK_FILE` (default `/run/lock/lore-deploy.lock`).

| Exit code | Meaning |
|---|---|
| 0 | deployed, or nothing to do |
| 1 | the deploy failed; the files are back, and the server too if it was touched. The output says whether that rollback is healthy |
| 2 | refused or failed before changing anything: bad option, edited tracked file, missing `.env`, fetch failed |
| 3 | the target commit failed before, or the last rollback left the server unhealthy; fix it, then pass `--force` |
| 4 | another deploy or a backup holds the lock |

State lives in `/opt/lore/deploy/.deploy/` (ignored by git):

| File | Holds |
|---|---|
| `history.log` | one line per deploy, failure and rollback |
| `failed` | commits not to deploy again without `--force` |
| `good`, `good.env` | the running healthy state: commit, image, the backup taken before it, `.env` |
| `prev`, `prev.env` | the healthy state before it, which `--rollback` restores |
| `pending` | a failed deploy left in place with `--no-rollback`; `--rollback` then puts back what it replaced |
| `broken` | a rollback that didn't come up healthy; deploys exit 3 until one with `--force` or a `--rollback` succeeds |
| `failed.env` | the `.env` a failed deploy tried, when it differs from the restored one |

`tests/test-deploy.sh` tests both scripts with stub `docker`, `sudo` and `runuser` commands; run it after changing `deploy.sh` or `backup.sh`.

## Part 3: automating it

The server pulls from GitHub on a timer. That needs nothing new: no inbound SSH, no deploy keys (the repository is public), and no secrets in GitHub. A merge to `main` is live within the timer's interval.

Know what that means before you turn it on: the timer runs `deploy.sh` and `backup.sh` from `main` as root, with no signature check. Anyone who can merge to `main` of game-dev-snowl/lore, or who takes over the GitHub account or repository, gets root on the server within 10 minutes. Protect `main` (required reviews, no force pushes) and keep the people who can merge to it few.

### Option A: deployment files on a timer, image upgrades by hand (recommended)

The timer runs `deploy.sh` every 10 minutes, as root, so the backup before an image change needs no password. `deploy.sh` runs git as the owner of `/opt/lore/deploy`, so the clone doesn't become root-owned. Image upgrades stay a deliberate `--version` you run yourself, after reading the release notes.

Create the unit files on the server:

```bash
sudo tee /etc/systemd/system/lore-deploy.service >/dev/null <<'EOF'
[Unit]
Description=Deploy new Lore Server changes from origin/main
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/lore/deploy/scripts/deploy.sh --yes
# Not new failures: 3 = this commit failed before, waiting for a fix;
# 4 = a backup or a deploy you started by hand holds the lock.
SuccessExitStatus=3 4
EOF

sudo tee /etc/systemd/system/lore-deploy.timer >/dev/null <<'EOF'
[Unit]
Description=Check for Lore Server changes every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lore-deploy.timer
```

Check it:

```bash
systemctl list-timers lore-deploy.timer
sudo systemctl start lore-deploy.service      # run once now
journalctl -u lore-deploy.service -n 50       # its output
cat /opt/lore/deploy/.deploy/history.log
```

To pause automatic deploys, for example while you debug on the server: `sudo systemctl stop lore-deploy.timer`. Start it again when done.

The nightly backup (`/etc/cron.d/lore-backup`) and the timer share the lock: a deploy that starts during a backup exits 4 and runs at the next tick, and a backup that starts during a deploy waits for it.

### Option B: the image version in git

To upgrade the image with a pull request as well, keep the version in the repository instead of `.env`:

1. Delete the `LORE_VERSION=` line from `/opt/lore/deploy/.env`. Compose then takes the default in `docker-compose.yml`, `${LORE_VERSION:-0.13.0}`.
2. To upgrade, change that default in `docker-compose.yml` in a pull request, after reading the release notes, and merge it.

The timer sees the image change, pulls it, takes the backup, and starts it, rolling back if it isn't healthy. The trade-off: a merge upgrades production without anyone at the server. If the new version changes the store format and fails, the automatic rollback restarts the old image, which may not read the stores. That case needs the backup restored by hand ([Rolling back](#rolling-back)). Don't pass `--version` once you've done this: it writes `LORE_VERSION` back into `.env`, which then overrides the file.

### Being told when a deploy fails

`journalctl -u lore-deploy.service` has every run. A failed fetch exits 2, so a GitHub or network outage alerts too. To get a message when one fails, add an `OnFailure=` unit to the service that sends mail or calls a webhook, for example:

```ini
# in [Unit] of lore-deploy.service
OnFailure=lore-deploy-alert.service
```

```ini
# /etc/systemd/system/lore-deploy-alert.service
[Service]
Type=oneshot
ExecStart=/usr/bin/curl -fsS -d "lore deploy failed on %H: journalctl -u lore-deploy" https://ntfy.sh/<your-private-topic>
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `tracked files were changed on the server` | Someone edited a file on the server. `git diff` shows it. Move the change into the repository, then `git checkout -- <file>`. |
| `<commit> failed to deploy before` (exit 3) | The last deploy of that commit failed and was rolled back. Fix it on `main`; the next commit deploys. To retry the same commit: `--force`. |
| `another deploy or a backup is running` (exit 4) | The timer or a backup is mid-run. Wait, or check `pgrep -af 'deploy.sh\|backup.sh'`. The lock is released when the process exits, even if it was killed. |
| `no healthy state is recorded to go back to` | `.env` names another image than the one running, and `deploy.sh` has never run here. Undo the edit, run `deploy.sh` once, then upgrade with `--version`. |
| `the last rollback left the server unhealthy` (exit 3) | A rollback didn't come up. Fix the server by hand, then `deploy.sh --force`, or `--rollback` again. |
| `run this as <user>, who owns …` | The script runs git as the clone's owner. Run it as that user, or with `sudo`. |
| `isn't a git clone` | The server still runs the rsync copy. [GIT-DEPLOY.md, part B](GIT-DEPLOY.md#b-replace-an-existing-rsync-copy). |
| `the clone is on 'X', not 'main'` | `git -C /opt/lore switch main`, or pass `--branch X`. |
| `crash-looping` or `unhealthy` after a deploy | The output shows the server's last log lines; the deploy was rolled back. Usually a config key the new version doesn't accept, or a TOML error. Run with `--no-rollback` to keep it running while you look: `docker compose logs loreserver`. |
| A pull fails with `not found` | The version doesn't exist as an image. Tags have no leading `v`: `0.14.0`, not `v0.14.0`. |
| The backup fails | The deploy is rolled back before the new image starts, and the commit isn't marked failed. Check free space in `/srv/lore/backups` (`df -h /srv/lore`) and `zstd` is installed. |
| `.env` changed back after a failed deploy | A failure restores the last healthy `.env`. The one the deploy tried is in `.deploy/failed.env`. |
