# Updating the server

How to roll out changes to the Lore Server: this update, every later one, and how to run updates unattended. All of it goes through `scripts/deploy.sh`, which runs on the server, in the git clone from [GIT-DEPLOY.md](GIT-DEPLOY.md).

There are two kinds of change, and they reach the server by different routes:

| Change | Where it comes from | How it reaches the server |
|---|---|---|
| Deployment files: `docker-compose.yml`, `config/local.toml`, `scripts/`, docs | this repository, `deploy/` on `main` | `./scripts/deploy.sh` (a `git pull` that restarts what it must) |
| The Lore Server program itself | an official image, `ghcr.io/epicgames/lore/loreserver:<version>` | `./scripts/deploy.sh --version <version>` (sets `LORE_VERSION` in `.env`) |

Server code merged into this fork from EpicGames/lore, such as the composite store's round-robin read replicas, isn't in any image yet. The workspace version is `0.13.1-nightly`, and the newest image is `0.13.0` (`latest` is the same image). That code reaches the server when Epic publishes the next release and you move to it with `--version`. Building your own image from the nightly source is possible (`lore-server/Dockerfile`), but this guide doesn't cover it: it would run unreleased code against your stores.

## What deploy.sh does

```text
fetch origin/main ─▶ show plan ─▶ fast-forward clone ─▶ docker compose config
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
                                  wait for "healthy" ── fails ─▶ put files back, start old
                                                                 server, remember the commit
```

| Changed file | Action | Downtime |
|---|---|---|
| `scripts/*`, `docs/*`, `auth0/*`, anything outside `deploy/` | none | none |
| `config/local.toml`, `certs/*` | `docker compose restart` | ~5–10 s |
| `docker-compose.yml` | `docker compose up -d` (recreate) | ~5–10 s |
| image (`--version`, or a different image in the files) | pull, backup, recreate | ~1 min backup + ~10 s |

Safety rails:

- It refuses to run while a tracked file is edited on the server, while another deploy runs, or when `origin/main` doesn't contain the deployed commit.
- It waits until Docker reports the container healthy, and gives up early if the server is crash-looping (a bad `local.toml` fails in about 10 s).
- On failure it rolls back on its own: the previous commit, the previous `.env`, the previous container. The failed commit goes into `.deploy/failed`, so an unattended run won't try it again until a newer commit lands, or you pass `--force`.
- It never changes the stores. If a new image changed the store format, going back to the old image needs the backup restored ([Rolling back](#rolling-back)).

## Part 1: this update

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

It lists the commits and files under `deploy/` that the server doesn't have yet, and what it would restart. Nothing changes. At the time of writing, a clone from before 11 November gets `scripts/trace-auth.sh` (a client-side login diagnostic), this guide, `scripts/deploy.sh` and the safer `scripts/backup.sh`. None of these needs a restart.

### 4. Deploy

```bash
./scripts/deploy.sh
```

It shows the plan, asks `Apply? [y/N]`, and finishes with `deployed <commit>, running <image>` and the container status, which should end in `(healthy)`. Check it from a client too:

```bash
lore repository list lores://<LORE_DOMAIN>:41337
```

### 5. The image stays at 0.13.0

`0.13.0` is the newest image, so there's no `--version` step this time. When Epic publishes a newer one, follow [Upgrading the Lore image](#upgrading-the-lore-image).

## Part 2: every later update

### Changing the deployment files

1. Change the file in the repository, on your machine or on GitHub. Never on the server: `deploy.sh` refuses to run over an edit to a tracked file.
2. Open a pull request and merge it to `main`.
3. On the server: `cd /opt/lore/deploy && ./scripts/deploy.sh`, or let the timer do it ([Part 3](#part-3-automating-it)).

Host-local values (domain, bind addresses, data directory, image version) live in `.env`, which isn't in git. After editing `.env` by hand, run `./scripts/deploy.sh --force` so the container picks it up and is health-checked.

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

Right after a deploy, back to the state before it:

```bash
./scripts/deploy.sh --rollback
```

It restores the previous commit and `.env` and recreates the container. It goes back one step: it doesn't keep a history of states.

If the deploy you're undoing changed the image, and the new version changed the store format, the old image may not read the stores any more. Restore the backup the deploy took (`ls -t /srv/lore/backups | head -1`):

```bash
docker compose stop loreserver
sudo sh -c 'rm -rf /srv/lore/data/* && tar -C /srv/lore/data --zstd -xf /srv/lore/backups/lore-data-<stamp>.tar.zst'
docker compose start loreserver
```

This loses every push made since the backup.

To undo a change for good, revert the commit on `main` and deploy. A rollback alone leaves `main` ahead of the server, and the next deploy brings the change back, unless the commit is in `.deploy/failed`.

### Reference

```text
./scripts/deploy.sh [--check] [--yes] [--version X.Y.Z] [--branch NAME]
                    [--force] [--no-backup] [--no-rollback] [--rollback]
```

| Option | Meaning |
|---|---|
| `--check` | show the plan, change nothing |
| `--yes` | don't ask; implied when there's no terminal (timer, cron, CI) |
| `--version X.Y.Z` | set `LORE_VERSION` in `.env` |
| `--branch NAME` | deploy another branch (default `main`); the clone must be on it |
| `--force` | recreate the container even when nothing changed (after a hand edit to `.env`), or retry a failed commit |
| `--no-backup` | skip the backup before an image change |
| `--no-rollback` | leave a failed deploy running, to debug it; undo with `--rollback` |
| `--rollback` | restore the commit and `.env` from before the last deploy |

Environment: `HEALTH_TIMEOUT` (default 180 s), `BACKUP_DIR` (default `/srv/lore/backups`), `DEPLOY_BRANCH`.

| Exit code | Meaning |
|---|---|
| 0 | deployed, or nothing to do |
| 1 | the deploy failed and was rolled back; read the output to see whether the rollback is healthy |
| 2 | refused before changing anything: bad option, edited tracked file, lock held, missing `.env` |
| 3 | the target commit failed before; push a fix or pass `--force` |

State lives in `/opt/lore/deploy/.deploy/` (ignored by git): `history.log` (one line per deploy), `failed` (commits that failed), `before` and `env.before` (what `--rollback` restores), `lock`.

## Part 3: automating it

The server pulls from GitHub on a timer. That needs nothing new: no inbound SSH, no deploy keys (the repository is public), and no secrets in GitHub. A merge to `main` is live within the timer's interval.

### Option A: deployment files on a timer, image upgrades by hand (recommended)

The timer runs `deploy.sh` every 10 minutes, as root, so the backup before an image change needs no password. `deploy.sh` runs git as the owner of `/opt/lore`, so the clone doesn't become root-owned. Image upgrades stay a deliberate `--version` you run yourself, after reading the release notes.

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
# Exit 3 means "this commit failed before, waiting for a fix": not a new failure.
SuccessExitStatus=3
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

The nightly backup (`/etc/cron.d/lore-backup`, 04:15) and the timer don't share a lock. If a deploy lands while a backup runs, the restart cuts the backup short. Avoid merging to `main` around 04:15, or stop the timer during that window with a `OnCalendar=` schedule in place of `OnUnitActiveSec=`.

### Option B: the image version in git

To upgrade the image with a pull request as well, keep the version in the repository instead of `.env`:

1. Delete the `LORE_VERSION=` line from `/opt/lore/deploy/.env`. Compose then takes the default in `docker-compose.yml`, `${LORE_VERSION:-0.13.0}`.
2. To upgrade, change that default in `docker-compose.yml` in a pull request, after reading the release notes, and merge it.

The timer sees the image change, pulls it, takes the backup, and starts it, rolling back if it isn't healthy. The trade-off: a merge upgrades production without anyone at the server. If the new version changes the store format and fails, the automatic rollback restarts the old image, which may not read the stores. That case needs the backup restored by hand ([Rolling back](#rolling-back)). Don't pass `--version` once you've done this: it writes `LORE_VERSION` back into `.env`, which then overrides the file.

### Being told when a deploy fails

`journalctl -u lore-deploy.service` has every run. To get a message when one fails, add an `OnFailure=` unit to the service that sends mail or calls a webhook, for example:

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
| `another deploy is running` | The timer is mid-run, or a run was killed. Wait, or check `pgrep -af deploy.sh`. The lock is released when the process exits. |
| `isn't a git clone` | The server still runs the rsync copy. [GIT-DEPLOY.md, part B](GIT-DEPLOY.md#b-replace-an-existing-rsync-copy). |
| `the clone is on 'X', not 'main'` | `git -C /opt/lore switch main`, or pass `--branch X`. |
| `crash-looping` or `unhealthy` after a deploy | The output shows the server's last log lines; the deploy was rolled back. Usually a config key the new version doesn't accept, or a TOML error. Run with `--no-rollback` to keep it running while you look: `docker compose logs loreserver`. |
| A pull fails with `not found` | The version doesn't exist as an image. Tags have no leading `v`: `0.14.0`, not `v0.14.0`. |
| The backup fails | The deploy is rolled back before the new image starts. Check free space in `/srv/lore/backups` (`df -h /srv/lore`) and `zstd` is installed. |
