# Deploy from a git clone

This runbook puts a clone of [game-dev-snowl/lore](https://github.com/game-dev-snowl/lore) at `/opt/lore` on the server, instead of the copy made with `rsync`. The deployment runs from `/opt/lore/deploy`, and an update is a `git pull`.

The clone is sparse: it checks out `deploy/` and the files at the repository root, about 4 MB, not Lore's source. The repository is public, so the server needs no GitHub credentials.

The values below are for the home-LAN server. For the public mode, follow [DEPLOYMENT.md](DEPLOYMENT.md) from step 1, running every command in `/opt/lore/deploy`.

| Value | Meaning |
|---|---|
| `192.168.1.29` | server LAN IP |
| `192.168.1.0/24` | LAN subnet |
| `lore.lan` | name clients use |

## What changes compared with the rsync copy

| | rsync copy | git clone |
|---|---|---|
| Working directory | `/opt/lore` | `/opt/lore/deploy` |
| Update | `rsync` from your machine | `git pull` on the server |
| Backup cron | `/opt/lore/scripts/backup.sh` | `/opt/lore/deploy/scripts/backup.sh` |
| Host-local files (`.env`, `certs/*.pem`, `ca/`) | in `/opt/lore` | in `/opt/lore/deploy`, ignored by git |

The scripts find their folder from their own path, so they work unchanged in `/opt/lore/deploy`. The Compose project is named `lore` in `docker-compose.yml`, so the container stays `loreserver` whichever folder it runs from. The stores live in `LORE_DATA_DIR` (`/srv/lore/data`), outside the clone, and aren't touched.

Never edit tracked files on the server, such as `config/local.toml` or `docker-compose.yml`: the next `git pull` refuses to run. Change them in the repository, push to `main`, and pull.

## A. Fresh server

Do this on a server that has never run Lore. If `/opt/lore` already holds the rsync copy, go to [B](#b-replace-an-existing-rsync-copy).

### 1. Clone

On the server, as your user:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo mkdir -p /opt/lore && sudo chown "$USER": /opt/lore
git clone --filter=blob:none --sparse https://github.com/game-dev-snowl/lore.git /opt/lore
git -C /opt/lore sparse-checkout set deploy
cd /opt/lore/deploy
ls                       # README.md  auth0  certs  config  docker-compose.yml  docs  scripts
```

### 2. Prepare the host

```bash
sudo LORE_LAN_CIDR=192.168.1.0/24 ./scripts/setup-server.sh "$USER"
exit                     # log out and back in so the docker group membership applies
```

[LINUX-SETUP.md](LINUX-SETUP.md) describes what the script does. It's safe to re-run.

### 3. Configure

```bash
cd /opt/lore/deploy
cp .env.example .env
nano .env
```

`.env.example` already holds the home-LAN values. Check them:

```dotenv
LORE_DOMAIN=lore.lan
LORE_VERSION=0.13.0
LORE_DATA_DIR=/srv/lore/data
LORE_BIND_ADDR=192.168.1.29
LORE_HTTP_BIND_ADDR=192.168.1.29
RUST_LOG=info
```

### 4. Issue the certificate and start

```bash
./scripts/make-local-ca.sh        # creates ca/ and certs/, prints "OK" and the expiry date
docker compose pull
docker compose up -d
docker compose ps                 # wait for "(healthy)"
curl -i http://192.168.1.29:41339/health_check   # HTTP/1.1 200 OK
```

Then continue with [HOME-LAN.md](HOME-LAN.md) §4 to §6 (trust the CA on each client, name resolution, connect), and turn on sign-in with [AUTH0.md](AUTH0.md). Where those pages say `/opt/lore`, use `/opt/lore/deploy`. For example, the CA to copy to clients is now at `/opt/lore/deploy/ca/ca.pem`:

```bash
scp <user>@192.168.1.29:/opt/lore/deploy/ca/ca.pem ~/lore-home-ca.pem
```

### 5. Schedule backups

```bash
echo '15 4 * * * root /opt/lore/deploy/scripts/backup.sh >> /var/log/lore-backup.log 2>&1' | sudo tee /etc/cron.d/lore-backup
```

Copy `/srv/lore/backups` off the box, and back up `/opt/lore/deploy/.env` and `/opt/lore/deploy/ca/` too ([HOME-LAN.md](HOME-LAN.md) §7).

## B. Replace an existing rsync copy

Do this when `/opt/lore` already runs Lore from an rsync copy. The server is down from step 2 to step 4, a minute or two. The stores in `/srv/lore/data` stay where they are.

### 1. Take a backup

```bash
cd /opt/lore
sudo ./scripts/backup.sh
```

### 2. Stop the server and move the old copy aside

```bash
cd /opt/lore
docker compose down
cd /
sudo mv /opt/lore /opt/lore.old
```

### 3. Clone, and bring the host-local files across

```bash
sudo apt-get install -y git
sudo mkdir -p /opt/lore && sudo chown "$USER": /opt/lore
git clone --filter=blob:none --sparse https://github.com/game-dev-snowl/lore.git /opt/lore
git -C /opt/lore sparse-checkout set deploy
cd /opt/lore/deploy

cp -a /opt/lore.old/.env .env
sudo cp -a /opt/lore.old/certs/. certs/
[ -d /opt/lore.old/ca ] && sudo cp -a /opt/lore.old/ca ca
```

Then add the line that publishes plain HTTP on the LAN, if `.env` doesn't have it yet:

```bash
grep -q '^LORE_HTTP_BIND_ADDR=' .env || printf '\nLORE_HTTP_BIND_ADDR=192.168.1.29\n' >> .env
```

### 4. Start

```bash
docker compose up -d
docker compose ps                 # wait for "(healthy)"
curl -i http://192.168.1.29:41339/health_check   # HTTP/1.1 200 OK
```

Clients need no change: the certificate and the CA are the same files.

### 5. Point the scheduled jobs at the new folder

```bash
sudo sed -i 's#/opt/lore/scripts/#/opt/lore/deploy/scripts/#' /etc/cron.d/lore-backup
cat /etc/cron.d/lore-backup
```

Public mode only: certbot stores the deploy hook's path with the certificate. Point it at the new folder and test it:

```bash
sudo sed -i 's#LORE_DIR=/opt/lore /opt/lore/scripts/#LORE_DIR=/opt/lore/deploy /opt/lore/deploy/scripts/#' /etc/letsencrypt/renewal/*.conf
sudo grep renew_hook /etc/letsencrypt/renewal/*.conf   # certbot stores --deploy-hook as renew_hook
sudo certbot renew --dry-run
```

### 6. Remove the old copy

Once the server has run healthy for a day and a backup has run from the new path:

```bash
sudo rm -rf /opt/lore.old
```

To roll back before then: `cd /opt/lore/deploy && docker compose down`, swap the folders back (`sudo mv /opt/lore /opt/lore.git && sudo mv /opt/lore.old /opt/lore`), and run `docker compose up -d` in `/opt/lore`.

## Updating

Change files in the repository, from your machine or on GitHub, and merge to `main`. Then on the server:

```bash
cd /opt/lore/deploy
git pull --ff-only
docker compose up -d                  # after a docker-compose.yml or .env change
docker compose restart loreserver     # after a config/local.toml change only
```

Upgrading the Lore image is still a `.env` change: bump `LORE_VERSION`, then `docker compose pull && docker compose up -d` ([DEPLOYMENT.md](DEPLOYMENT.md) §5). Take a backup first.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `git pull` says local changes would be overwritten | A tracked file was edited on the server. `git diff` shows it. Move the change to the repository, then `git checkout -- <file>` and pull again. |
| `ls /opt/lore/deploy` doesn't exist | The `sparse-checkout set deploy` step was skipped. Run it in `/opt/lore`. |
| `fatal: detected dubious ownership` | git is running as a user other than the owner of `/opt/lore`, e.g. under `sudo`. Run `git pull` as your own user, without `sudo`. |
| Container keeps restarting after the move | `certs/` is empty. Copy the files from `/opt/lore.old/certs`, or run `make-local-ca.sh` again (it reuses `ca/`). |
| `docker compose` says the container name `loreserver` is in use | The old copy is still running. Run `docker compose down` in `/opt/lore.old`. |
