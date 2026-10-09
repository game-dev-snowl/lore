#!/usr/bin/env bash
# Prepare a fresh Ubuntu 22.04/24.04 or Debian 12 x86_64 host for Lore Server.
# Idempotent: safe to re-run.
#
#   sudo ./scripts/setup-server.sh [deploy-user]
#
# Does: base packages, unattended security upgrades, Docker Engine + Compose
# plugin, certbot, UFW firewall, QUIC-friendly UDP buffers, data directory.
# Does NOT touch SSH config — see docs/LINUX-SETUP.md for hardening.
set -euo pipefail

DEPLOY_USER="${1:-${SUDO_USER:-}}"
DATA_DIR="${LORE_DATA_DIR:-/srv/lore/data}"

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

arch="$(dpkg --print-architecture)"
if [[ "$arch" != "amd64" ]]; then
  echo "WARNING: host is $arch. The loreserver image is linux/amd64 only;" >&2
  echo "the arm64 build targets AWS Graviton3+ and crashes (SIGILL) on other ARM CPUs." >&2
  read -rp "Continue anyway? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

. /etc/os-release
echo "==> Host: $PRETTY_NAME ($arch)"

echo "==> Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git ufw openssl \
  unattended-upgrades apt-listchanges fail2ban certbot htop jq zstd

echo "==> Unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Docker Engine + Compose plugin (official repo)"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

if [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "root" ]]; then
  usermod -aG docker "$DEPLOY_USER"
  echo "    added $DEPLOY_USER to the docker group (re-login to take effect)"
fi

echo "==> Docker daemon log rotation"
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
EOF
  systemctl restart docker
fi

echo "==> Kernel: UDP buffers for QUIC"
cat > /etc/sysctl.d/90-lore-quic.conf <<'EOF'
# QUIC (quinn) throughput: allow large UDP socket buffers
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
sysctl --system >/dev/null

echo "==> Firewall (UFW)"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp     comment "certbot HTTP-01 challenge"
ufw allow 41337/tcp  comment "lore gRPC"
ufw allow 41337/udp  comment "lore QUIC"
ufw --force enable
# NOTE: Docker-published ports bypass UFW (Docker writes iptables directly).
# Restrict 41337 with LORE_BIND_ADDR in .env, the DOCKER-USER chain, or the
# cloud provider's firewall — not with UFW alone.

echo "==> Data directory: $DATA_DIR"
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

echo
echo "Done. Next: docs/DEPLOYMENT.md, step 3 (clone + .env)."
