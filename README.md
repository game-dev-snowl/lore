# Lore Server deployment

Docker Compose deployment of [Lore](https://lore.org) (Epic Games' open-source VCS for code + large binary assets): a single `loreserver` node with local storage and a Let's Encrypt TLS certificate.

> [!WARNING]
> **There is no authentication by default.** With no `[server.auth]` in `config/local.toml`, anyone who can reach port 41337 can list, clone and push every repository. They can also call admin RPCs, including **obliterate**: the server logs `No JWT verifier - Admin Service RPCs including obliterate will be unauthenticated` at startup. To keep it private, set `LORE_BIND_ADDR` to a VPN or Tailscale IP, or enable Auth0 sign-in with role-based permissions: [docs/AUTH0.md](docs/AUTH0.md).

## Layout

```
.
├── docker-compose.yml          # loreserver service (ghcr.io/epicgames/lore/loreserver)
├── .env.example                # domain, image version, data dir → copy to .env
├── config/local.toml           # server overlay: TLS cert paths, stores, logging, (auth)
├── certs/                      # populated by certbot hook (git-ignored)
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

## Quick start: public mode (on the server)

```bash
git clone <this-repo> /opt/lore && cd /opt/lore
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
