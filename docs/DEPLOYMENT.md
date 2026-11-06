# Deployment

Prerequisite: the host has been prepared as described in [LINUX-SETUP.md](LINUX-SETUP.md). That covers Docker, certbot, the firewall, DNS, and `/srv/lore/data`.

## How it fits together

```
 lore CLI ──lores://lore.example.com:41337──►  UDP 41337 (QUIC, TLS)  ┐
                                              TCP 41337 (gRPC, TLS)  ├─ loreserver container
                     127.0.0.1:41339 ◄── health check (plain HTTP)   ┘     │
                                                                           ├─ /etc/lore/config/local.toml  ← ./config/local.toml
 certbot (host) ──deploy hook──► ./certs/{fullchain,privkey}.pem ──────────┤  /etc/lore/certs            ← ./certs
                                                                           └─ /data                      ← $LORE_DATA_DIR
```

Config layering inside the image: compiled-in defaults → `/etc/lore/config/default.toml` → `docker.toml` (`LORE_ENV=docker`, stores at `/data`) → **our `local.toml`** → `LORE__*` env vars.

**`lores://` vs `lore://`.** The CLI only verifies the server certificate when the URL scheme ends in `s`. With `lores://` it checks QUIC and gRPC against the OS trust store, which is why both endpoints have the Let's Encrypt cert. With `lore://` the connection is still encrypted, but the server is never verified, so it is open to MITM. Always use `lores://` with this setup.

## 1. Configure

```bash
cd /opt/lore
cp .env.example .env
nano .env
```

| Var | Set to |
|---|---|
| `LORE_DOMAIN` | the DNS name, e.g. `lore.example.com` |
| `LETSENCRYPT_EMAIL` | your email for expiry notices |
| `LORE_VERSION` | the pinned image tag. Check the [releases](https://github.com/EpicGames/lore/releases) page |
| `LORE_DATA_DIR` | `/srv/lore/data` (absolute path, on the data volume) |
| `LORE_BIND_ADDR` | `0.0.0.0` to publish publicly, or a VPN IP to keep it private |

## 2. Get the TLS certificate

```bash
sudo ./scripts/issue-cert.sh
ls -l certs/        # fullchain.pem (644), privkey.pem (600)
```

This runs `certbot certonly --standalone`, which temporarily binds :80. It registers `scripts/certbot-deploy-hook.sh` as the deploy hook **for this certificate only**. On each renewal (every ~60 days, via `certbot.timer`) the hook copies the new files into `./certs` and runs `docker compose restart loreserver`. Expect a few seconds of downtime each time.

Test the renewal path without spending rate limit:

```bash
sudo certbot renew --dry-run
```

> If you later put nginx or Caddy on :80, switch the cert to `--webroot` (or let that proxy manage the cert) so that renewal doesn't fight over the port.

## 3. Start

```bash
docker compose pull
docker compose up -d
docker compose ps                     # STATUS should become "healthy"
docker compose logs -f loreserver     # JSON logs
curl -i http://127.0.0.1:41339/health_check
```

## 4. Verify from your machine

```bash
# TLS on the TCP side (gRPC), expect the Let's Encrypt chain and "Verify return code: 0"
openssl s_client -connect lore.example.com:41337 -servername lore.example.com -alpn h2 </dev/null 2>/dev/null | grep -E 'subject=|issuer=|Verify return'

# UDP reachability
nc -vzu lore.example.com 41337
```

Install the CLI on a client:

```bash
curl -fsSL https://raw.githubusercontent.com/EpicGames/lore/main/scripts/install.sh | bash
```

Then use it:

```bash
lore repository create lores://lore.example.com:41337/my-project
lore clone lores://lore.example.com:41337/my-project
lore repository list lores://lore.example.com:41337
```

Always give the port explicitly. Without it, `lores://` defaults gRPC to **443**, not 41337.

## 5. Day-2 operations

### Upgrade the server

```bash
cd /opt/lore
git pull
nano .env                 # bump LORE_VERSION (read the release notes first: config keys do change)
docker compose pull
docker compose up -d      # recreates the container; ~5-30 s downtime
docker compose ps
```

Roll back by setting the old `LORE_VERSION` and running `up -d` again. **Take a backup before upgrading.** The store format can change between 0.x releases.

### Backups

```bash
sudo ./scripts/backup.sh                    # → /srv/lore/backups/lore-data-<UTC>.tar.zst, keeps 14
```

This is a cold backup: it stops the server, archives, and restarts, so expect about a minute of downtime. The stores flush on a delay, so copying them while the server runs could capture an inconsistent state. Schedule it:

```bash
echo '15 4 * * * root /opt/lore/scripts/backup.sh >> /var/log/lore-backup.log 2>&1' | sudo tee /etc/cron.d/lore-backup
```

Copy the archives **off the host** (e.g. `rclone` to a Hetzner Storage Box or S3). A backup that sits on the same disk does not protect you.

Restore:

```bash
docker compose stop loreserver
sudo rm -rf /srv/lore/data/* && sudo tar -C /srv/lore/data --zstd -xf /srv/lore/backups/lore-data-<stamp>.tar.zst
docker compose start loreserver
```

### Configuration changes

Edit `config/local.toml`, commit, pull on the server, then `docker compose restart loreserver`. Single scalar values can also be set as env vars in `docker-compose.yml`, e.g. `LORE__SERVER__HTTP__STORE_HEALTH_CHECK: "true"`.

### Useful commands

```bash
docker compose logs --since 1h loreserver | jq -r '.fields.message // .'
docker stats loreserver
du -sh /srv/lore/data
df -h /srv/lore
```

The server logs a warning when free space on the store volume drops below 10 GiB (`server.local_store_monitor`).

## 6. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Container restarts and the logs mention `certificate` / `No such file` | `./certs` is empty. Run `sudo ./scripts/issue-cert.sh`. |
| `exec format error` or `SIGILL` | The host is ARM. Use an amd64 host. |
| Client hangs and TCP works but QUIC doesn't | UDP 41337 is blocked by the provider firewall. |
| Client TLS error with `lores://` | The URL hostname doesn't match `LORE_DOMAIN`, or the cert expired. Check `sudo certbot certificates`. |
| Client tries port 443 | The port is missing from the URL. Add `:41337`. |
| `PluginNotFound` at startup | `aws` was selected as the store or lock mode. The stock image doesn't include the AWS plugin. |
| Unhealthy and nothing on 41339 | Run `docker compose logs loreserver`. A config key may have been removed in a newer `LORE_VERSION`. |

## 7. Enabling authentication

Out of the box the server is **unauthenticated**. To require sign-in with Auth0 and role-based permissions, follow [AUTH0.md](AUTH0.md). The Auth0 block is already in `config/local.toml`, commented out. Other OIDC providers (e.g. Keycloak) use the same `[server.auth]` + `[server.auth.oidc]` tables. The fields `jwt_issuer`, `jwt_audience`, `permission_claim`, `resource_claim` and the rest are documented in the [config reference](https://epicgames.github.io/lore/reference/lore-server-config/#authentication).

## References

- Deploy a local Lore Server: https://epicgames.github.io/lore/how-to/deploy-local-lore-server/
- Server config reference: https://epicgames.github.io/lore/reference/lore-server-config/
- Image docs: https://github.com/EpicGames/lore/blob/main/lore-server/DOCKER.md
