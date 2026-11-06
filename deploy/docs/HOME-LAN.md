# Home server, LAN-only deployment

This runbook is for running Lore on the home server (Ubuntu Server, RAID 1), reachable only from the local network. Let's Encrypt can't reach a LAN-only host, so `make-local-ca.sh` creates a small private CA instead. Clients trust that CA once and use `lores://`, so the server certificate is still fully verified.

These are the values for this deployment. Change them if yours differ:

| Value | Meaning | How to find it |
|---|---|---|
| `192.168.1.29` | server LAN IP | `ip -4 addr` on the server |
| `192.168.1.0/24` | LAN subnet | your router's network |
| `lore.lan` | name clients use | any name your LAN resolves |

## 0. Before you start

- **Give the server a fixed IP.** Use a DHCP reservation on the router, or set it in netplan. The certificate has the IP in it, so if the IP changes the cert has to be re-issued.
- **Check the RAID is healthy.** Run `cat /proc/mdstat`. It should show `[UU]`. If you see `[U_]`, the mirror is degraded and you should fix that first.
- **RAID 1 is not a backup.** It survives a dead disk, but a deletion, corruption or a bad push gets copied to both disks. Step 7 covers real backups.

## 1. Prepare the host

To run from a git clone and update with `git pull` instead, follow [GIT-DEPLOY.md](GIT-DEPLOY.md), which replaces this step and uses `/opt/lore/deploy` in place of `/opt/lore`.

Otherwise, copy this folder to the server. Run this **on your machine, from this folder** ([details](DEPLOYMENT.md#0-copy-the-files-to-the-server)):

```bash
ssh <user>@<server> 'sudo mkdir -p /opt/lore && sudo chown "$USER": /opt/lore'
rsync -av --exclude .git --exclude .claude --exclude .env --exclude 'certs/*.pem' \
  --exclude ca/ --exclude data/ --exclude backups/ --exclude .DS_Store \
  ./ <user>@<server>:/opt/lore/
```

Then on the server:

```bash
cd /opt/lore

sudo LORE_LAN_CIDR=192.168.1.0/24 ./scripts/setup-server.sh "$USER"
# log out and back in so the docker group membership applies
```

With `LORE_LAN_CIDR` set, UFW opens 41337 (TCP and UDP) only to your subnet and doesn't open port 80. Docker-published ports bypass UFW, so the bindings in step 2 are what limit exposure.

## 2. Configure

```bash
cd /opt/lore
cp .env.example .env
nano .env
```

```dotenv
LORE_DOMAIN=lore.lan
LORE_VERSION=0.13.0
LORE_DATA_DIR=/srv/lore/data
LORE_BIND_ADDR=192.168.1.29
LORE_HTTP_BIND_ADDR=192.168.1.29
RUST_LOG=info
```

`LETSENCRYPT_EMAIL` isn't used in LAN mode. Setting `LORE_BIND_ADDR` to the LAN IP means Docker publishes 41337 on that interface only, and `LORE_HTTP_BIND_ADDR` does the same for 41339 (plain HTTP). Docker bypasses UFW, so these bindings are what actually limit exposure. They pick the interface, not who may connect: any host that can route to 192.168.1.29 (another VLAN, a VPN peer, a forwarded router port) reaches both ports. To restrict by source, add `DOCKER-USER` iptables rules.

## 3. Issue the certificate and start

```bash
./scripts/make-local-ca.sh        # creates ca/ and certs/, prints "OK" and the expiry date
docker compose pull
docker compose up -d
docker compose ps                  # wait for "(healthy)"
curl -i http://192.168.1.29:41339/health_check   # HTTP/1.1 200 OK
```

The server certificate is valid for **825 days**. To renew it, re-run `./scripts/make-local-ca.sh`. It reuses the CA, so clients don't need any changes, and it restarts the server. Put a reminder in your calendar.

Keep `ca/ca.key` secret: anyone who has it can create certificates your clients will trust. Back it up somewhere offline.

## 4. Trust the CA on each client

Copy `ca/ca.pem` to each client:

```bash
scp server:/opt/lore/ca/ca.pem ~/lore-home-ca.pem
```

Then install it on each OS.

**macOS**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/lore-home-ca.pem
```

**Linux (Debian/Ubuntu)**

```bash
sudo cp lore-home-ca.pem /usr/local/share/ca-certificates/lore-home-ca.crt && sudo update-ca-certificates
```

**Windows (admin PowerShell)**

```powershell
certutil -addstore -f Root lore-home-ca.pem
```

The Lore CLI loads the OS trust store as well as its built-in roots, which is why installing the CA there is enough.

## 5. Name resolution

You have three options:

- **Router DNS** (best): add a local record `lore.lan → 192.168.1.29`. Most routers, Pi-hole and AdGuard support this.
- **Per-client hosts file**: add `192.168.1.29 lore.lan` to `/etc/hosts`. On Windows the file is `C:\Windows\System32\drivers\etc\hosts`.
- **Skip DNS entirely**: use the IP in the URL. The certificate covers it too.

## 6. Connect

Install the CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/EpicGames/lore/main/scripts/install.sh | bash
```

Check the connection from a client:

```bash
openssl s_client -connect lore.lan:41337 -servername lore.lan -CAfile ~/lore-home-ca.pem </dev/null 2>/dev/null | grep 'Verify return'
# → Verify return code: 0 (ok)
```

Check plain HTTP from a client:

```bash
curl -i http://lore.lan:41339/health_check   # HTTP/1.1 200 OK
```

Port 41339 is plain HTTP. The `/v1` routes on it check the same Auth0 token as gRPC, but the token and the file contents it carries are not encrypted, so anyone on the LAN path can read or alter them. Clients use `lores://` on 41337 and don't need 41339. Don't forward 41339 on the router.

Then use Lore:

```bash
lore repository create lores://lore.lan:41337/my-project
lore clone lores://lore.lan:41337/my-project
```

Always include `:41337` in the URL. Without it, `lores://` sends gRPC to port 443.

## 7. Backups (RAID doesn't count)

```bash
sudo ./scripts/backup.sh                     # stops the server, archives /srv/lore/data, restarts; keeps 14
echo '15 4 * * * root /opt/lore/scripts/backup.sh >> /var/log/lore-backup.log 2>&1' | sudo tee /etc/cron.d/lore-backup
```

Then copy `/srv/lore/backups` **off the box**, for example to an external USB disk, a NAS, or a Hetzner Storage Box via `rclone`. Also back up `/opt/lore/.env` and `/opt/lore/ca/`.

## Upgrades and troubleshooting

These are the same as for the public deployment. See [DEPLOYMENT.md](DEPLOYMENT.md) §5 and §6.

| LAN-specific symptom | Cause |
|---|---|
| `make-local-ca.sh` says to set `LORE_BIND_ADDR` | It's still `0.0.0.0`. Set the LAN IP. |
| Container keeps restarting right after a fresh setup | `certs/` is empty. Run `make-local-ca.sh` first. |
| `hostname mismatch` / `UnknownIssuer` on a client | The CA isn't installed on that client, or the URL host isn't `LORE_DOMAIN` or the IP. |
| Was working, now refuses connections | The server IP changed. Fix the DHCP reservation, update `.env`, and re-run `make-local-ca.sh`. |
| Works on the server but not from the LAN | `LORE_HTTP_BIND_ADDR` is unset (41339 stays on loopback), or the client's network blocks it (Wi-Fi AP/client isolation). Check the published addresses with `docker compose ps`. |
| `curl http://127.0.0.1:41339` refused on the server | Expected: 41339 is published on `LORE_HTTP_BIND_ADDR`, not loopback. Use the LAN IP. |
