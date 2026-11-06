#!/usr/bin/env bash
# LAN mode: create a private CA (once) and issue a server certificate for
# LORE_DOMAIN + LORE_BIND_ADDR, so clients can use lores:// with real
# verification on a network Let's Encrypt can't reach.
#
#   sudo ./scripts/make-local-ca.sh          # issue / re-issue server cert
#
# Outputs:
#   ca/ca.pem, ca/ca.key        private CA (git-ignored; keep ca.key secret)
#   certs/fullchain.pem         server cert + CA
#   certs/privkey.pem           server key
# Then install ca/ca.pem as trusted on every client (see docs/HOME-LAN.md).
set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$LORE_DIR/.env" ]] || { echo "Missing $LORE_DIR/.env (copy .env.example)." >&2; exit 1; }
set -a; . "$LORE_DIR/.env"; set +a

: "${LORE_DOMAIN:?set LORE_DOMAIN in .env (e.g. lore.lan)}"
: "${LORE_BIND_ADDR:?set LORE_BIND_ADDR in .env to the server LAN IP}"
[[ "$LORE_BIND_ADDR" != "0.0.0.0" ]] || { echo "Set LORE_BIND_ADDR to the server's LAN IP, not 0.0.0.0." >&2; exit 1; }

CA_DIR="$LORE_DIR/ca"
CERT_DIR="$LORE_DIR/certs"
DAYS_CA=3650
DAYS_LEAF=825            # stay within Apple's 825-day TLS limit

install -d -m 0700 "$CA_DIR"
install -d -m 0750 "$CERT_DIR"

if [[ ! -f "$CA_DIR/ca.key" ]]; then
  echo "==> Creating private CA (valid $DAYS_CA days)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.pem" -days "$DAYS_CA" \
    -subj "/CN=Lore Home CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  chmod 600 "$CA_DIR/ca.key"
else
  echo "==> Reusing existing CA in $CA_DIR"
fi

echo "==> Issuing server cert for DNS:$LORE_DOMAIN, IP:$LORE_BIND_ADDR (valid $DAYS_LEAF days)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$tmp/server.key" -out "$tmp/server.csr" -subj "/CN=$LORE_DOMAIN"
cat > "$tmp/ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:$LORE_DOMAIN,IP:$LORE_BIND_ADDR
EOF
openssl x509 -req -in "$tmp/server.csr" -CA "$CA_DIR/ca.pem" -CAkey "$CA_DIR/ca.key" \
  -CAcreateserial -CAserial "$CA_DIR/ca.srl" -out "$tmp/server.pem" \
  -days "$DAYS_LEAF" -extfile "$tmp/ext" 2>/dev/null

cat "$tmp/server.pem" "$CA_DIR/ca.pem" > "$CERT_DIR/fullchain.pem"
install -m 0600 "$tmp/server.key" "$CERT_DIR/privkey.pem"
chmod 0644 "$CERT_DIR/fullchain.pem"

openssl verify -CAfile "$CA_DIR/ca.pem" "$tmp/server.pem"
echo "    expires: $(openssl x509 -enddate -noout -in "$tmp/server.pem" | cut -d= -f2)"

cd "$LORE_DIR"
if docker compose ps --status running --services 2>/dev/null | grep -qx loreserver; then
  docker compose restart loreserver
fi

echo
echo "Trust this CA on each client: $CA_DIR/ca.pem   (docs/HOME-LAN.md, step 4)"
