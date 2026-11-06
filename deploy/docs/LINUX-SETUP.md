# Linux environment setup

How to prepare a fresh host to run Lore Server. Tested against Ubuntu 24.04 LTS. Debian 12 and Ubuntu 22.04 should also work.

## 1. Choose the machine

| Requirement | Why |
|---|---|
| **x86_64 / amd64** | `ghcr.io/epicgames/lore/loreserver:<ver>` is published for `linux/amd64` only. The `-graviton` arm64 build uses SVE instructions that only AWS Graviton3+ has, so it crashes with `SIGILL` on Ampere hosts (e.g. Hetzner **CAX**). On Hetzner, pick **CX / CPX / CCX**. |
| 2+ vCPU, 4 GB+ RAM | The server is a Rust binary, so these are modest numbers. Size up based on how many clients run at the same time. |
| Disk sized for your assets | Every revision of every binary is kept in `/data`, so plan for growth and use a separate volume. |
| Public IPv4 (and/or IPv6) + DNS A/AAAA record | Let's Encrypt needs the record, and clients connect by name. |

Mount the data volume at `/srv/lore` (Hetzner Volumes: `mkfs.ext4` → `/etc/fstab` with `nofail` → `mount -a`).

## 2. First login and a deploy user

```bash
ssh root@SERVER_IP

adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/
chown deploy:deploy /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deploy   # or set a password instead

timedatectl set-timezone UTC
hostnamectl set-hostname lore-1
```

## 3. Harden SSH

This step is manual on purpose, because a mistake here can lock you out. Keep your current session open while you test a new one.

```bash
sudo tee /etc/ssh/sshd_config.d/90-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
sudo sshd -t && sudo systemctl reload ssh
```

From a **second terminal**: `ssh deploy@SERVER_IP` must work before you close the first one.

## 4. Run the setup script

First copy this folder to the server. Run this **on your machine, from this folder** ([details](DEPLOYMENT.md#0-copy-the-files-to-the-server)):

```bash
ssh deploy@<server> 'sudo mkdir -p /opt/lore && sudo chown deploy: /opt/lore'
rsync -av --exclude .git --exclude .claude --exclude .env --exclude 'certs/*.pem' \
  --exclude ca/ --exclude data/ --exclude backups/ --exclude .DS_Store \
  ./ deploy@<server>:/opt/lore/
```

Then on the server:

```bash
cd /opt/lore
sudo ./scripts/setup-server.sh deploy
exit   # log out and back in so the docker group membership applies
```

`setup-server.sh` does the following and is safe to re-run:

- Installs base packages, plus `unattended-upgrades` (automatic security patches) and `fail2ban` (SSH brute-force protection).
- Installs Docker Engine and the Compose plugin from Docker's apt repo, enables them on boot, and adds the user to the `docker` group.
- Turns on Docker log rotation.
- Installs `certbot`, which brings its `certbot.timer` renewal timer.
- Sets the `net.core.rmem_max` / `wmem_max` sysctls so QUIC doesn't get throttled by small UDP buffers.
- Sets up UFW: deny incoming, then allow SSH, 80/tcp, 41337/tcp and 41337/udp.
- Creates `/srv/lore/data` with mode `700`.

Check the result:

```bash
docker run --rm hello-world
docker compose version
sudo ufw status verbose
systemctl list-timers certbot.timer
sysctl net.core.rmem_max
```

## 5. Cloud firewall

UFW is not enough on its own. **Ports that Docker publishes skip UFW**, because Docker writes its own iptables rules. If you want to restrict who can reach 41337, use one of these:

- **Provider firewall** (Hetzner Cloud Firewall, AWS SG): allow 22/tcp, 80/tcp, 41337/tcp, **41337/udp**. Forgetting the UDP rule is the most common reason QUIC fails. Clients may then fall back to gRPC or simply fail.
- **`LORE_BIND_ADDR`** in `.env`: publish only on a WireGuard or Tailscale interface IP.
- **`DOCKER-USER` iptables chain**: drop traffic to 41337 unless it comes from allowlisted CIDRs.

## 6. DNS

Create `A` (and `AAAA` if you have IPv6) for `lore.example.com` → server IP. Check it:

```bash
dig +short lore.example.com
```

Continue with [DEPLOYMENT.md](DEPLOYMENT.md).
