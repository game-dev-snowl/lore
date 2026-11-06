# Lore Server deployment

Docker Compose deployment of [Lore](https://lore.org) (Epic Games' open-source VCS for code + large binary assets): a single `loreserver` node with local storage and a Let's Encrypt TLS certificate.

> [!IMPORTANT]
> **Auth0 sign-in is on.** `config/local.toml` requires an Auth0 access token from tenant `dev-tke5iflfv7b6gdca.eu.auth0.com` (API `https://lore.uzunov.me`); permissions come from each user's `app_metadata.lore_permissions` via an Auth0 Action (works on the Free plan). Setup, adding users and troubleshooting: [docs/AUTH0.md](docs/AUTH0.md). Without the `[server.auth]` table, anyone who can reach port 41337 can list, clone, push and **obliterate** every repository.

## Layout

```
.
├── docker-compose.yml          # loreserver service (ghcr.io/epicgames/lore/loreserver)
├── .env.example                # domain, image version, data dir → copy to .env
├── config/local.toml           # server overlay: TLS cert paths, stores, logging, (auth)
├── certs/                      # populated by certbot hook (git-ignored)
├── auth0/actions/              # Auth0 Actions that put lore_permissions in tokens
├── scripts/
│   ├── setup-server.sh         # fresh Ubuntu/Debian host → Docker, certbot, UFW, sysctl
│   ├── issue-cert.sh           # Let's Encrypt cert + renewal hook
│   ├── certbot-deploy-hook.sh  # copies renewed cert, restarts loreserver
│   └── backup.sh               # cold backup of the stores
└── docs/
    ├── LINUX-SETUP.md          # provisioning + hardening the host
    ├── DEPLOYMENT.md           # deploy, connect clients, upgrade, backup, troubleshoot
    └── AUTH0.md                # Auth0 sign-in + role-based permissions
```

## Two modes

| Mode | TLS | Runbook |
|---|---|---|
| **LAN-only** (home server) | private CA (`scripts/make-local-ca.sh`) | [docs/HOME-LAN.md](docs/HOME-LAN.md) |
| **Public** (VPS / datacenter) | Let's Encrypt (`scripts/issue-cert.sh`) | [docs/LINUX-SETUP.md](docs/LINUX-SETUP.md) → [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |

## Quick start: public mode

This folder isn't in a git remote. Copy it to the server from your machine ([details](docs/DEPLOYMENT.md#0-copy-the-files-to-the-server)):

```bash
ssh <user>@<server> 'sudo mkdir -p /opt/lore && sudo chown "$USER": /opt/lore'
rsync -av --exclude .git --exclude .claude --exclude .env --exclude 'certs/*.pem' \
  --exclude ca/ --exclude data/ --exclude backups/ --exclude .DS_Store \
  ./ <user>@<server>:/opt/lore/
```

Then on the server:

```bash
cd /opt/lore
sudo ./scripts/setup-server.sh "$USER"
cp .env.example .env && nano .env          # LORE_DOMAIN, LETSENCRYPT_EMAIL
sudo ./scripts/issue-cert.sh
docker compose up -d
curl -i http://127.0.0.1:41339/health_check   # → HTTP/1.1 200 OK
```

Client:

```bash
lore repository create lores://lore.example.com:41337/my-project
```

## Ports

| Port  | Proto | Purpose | Exposed |
|-------|-------|---------|---------|
| 41337 | TCP   | gRPC (TLS) | public |
| 41337 | UDP   | QUIC (TLS) | public |
| 41339 | TCP   | HTTP health check | 127.0.0.1 only |
| 80    | TCP   | certbot HTTP-01 (only during issue/renew) | public |

The full procedure is in [docs/LINUX-SETUP.md](docs/LINUX-SETUP.md), then [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
