#!/usr/bin/env bash
# Obtain a Let's Encrypt certificate for $LORE_DOMAIN and register the deploy
# hook that copies it into ./certs and restarts loreserver on every renewal.
#
#   sudo ./scripts/issue-cert.sh
#
# Requires: DNS for $LORE_DOMAIN pointing at this host, TCP 80 reachable and free.
# Renewal is automatic via certbot's systemd timer (certbot.timer).
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$LORE_DIR/.env" ]] || { echo "Missing $LORE_DIR/.env (copy .env.example)." >&2; exit 1; }
set -a; . "$LORE_DIR/.env"; set +a

: "${LORE_DOMAIN:?set LORE_DOMAIN in .env}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL in .env}"
[[ "$LORE_DOMAIN" != "lore.example.com" && "$LORE_DOMAIN" != "lore.lan" ]] || { echo "Set LORE_DOMAIN in .env to a public DNS name first." >&2; exit 1; }
# 41339 is plain HTTP; on a public host it stays on loopback.
[[ "${LORE_HTTP_BIND_ADDR:-127.0.0.1}" == "127.0.0.1" ]] || { echo "Public mode: delete LORE_HTTP_BIND_ADDR from .env (41339 is plain HTTP)." >&2; exit 1; }

HOOK="$LORE_DIR/scripts/certbot-deploy-hook.sh"
chmod +x "$HOOK"

certbot certonly \
  --standalone \
  --non-interactive --agree-tos \
  --email "$LETSENCRYPT_EMAIL" \
  --cert-name "$LORE_DOMAIN" \
  -d "$LORE_DOMAIN" \
  --deploy-hook "LORE_DIR=$LORE_DIR $HOOK" \
  --keep-until-expiring

# The deploy hook only fires on issuance/renewal; run it now so ./certs is
# populated even when the cert already existed.
RENEWED_LINEAGE="/etc/letsencrypt/live/$LORE_DOMAIN" LORE_DIR="$LORE_DIR" "$HOOK"

systemctl enable --now certbot.timer 2>/dev/null || true
echo "Certificate ready in $LORE_DIR/certs. Renewal: systemctl list-timers certbot.timer"
