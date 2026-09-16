#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hetzner box: Remote Orca Server + Open Knowledge (+GH sync) + Claude Code
# Model: the BOX owns the Orca runtime. Laptop AND phone pair in as clients
#        over Tailscale — both see/assign the same live sessions.
# Target: Hetzner CX53 (16 vCPU / 32GB x86 Intel) on Ubuntu 24.04.
# Run as root. Interactive browser-auth steps are marked ###PAUSE###.
#
# One service user, `orca`, owns everything (OK project, GitHub creds,
# Claude Code creds, and the Orca runtime) so agents Orca spawns are
# already authenticated. Two systemd services: openknowledge + orca-serve.
# ---------------------------------------------------------------------------
# ===========================================================================
# LAPTOP PREP (run these on your MacBook BEFORE creating the box) ============
#
#   # 1. Primary key — select its .pub in the Hetzner console at create time.
#   ssh-keygen -t ed25519 -C "jordan-laptop-$(date +%Y%m)" -f ~/.ssh/id_ed25519
#   #    Set a passphrase. Load into agent + Apple Keychain:
#   ssh-add --apple-use-keychain ~/.ssh/id_ed25519
#   cat ~/.ssh/id_ed25519.pub            # paste this into the Hetzner console
#
#   # 2. Recovery key — store its PRIVATE half only in your password manager.
#   ssh-keygen -t ed25519 -C "recovery-key" -f ~/.ssh/recovery_ed25519
#   cat ~/.ssh/recovery_ed25519.pub      # paste this into RECOVERY_PUBKEY below
#
# Back up ~/.ssh/id_ed25519 + its passphrase to a password manager, plus one
# encrypted offline copy. Never sync the private key unencrypted to any cloud.
# ===========================================================================
set -euo pipefail

# ---- 0. Config — set these as environment variables when you run the script -
# Public repo: keep your real values OUT of this file. Supply them at runtime:
#   GH_REPO_URL=https://github.com/you/knowledge.git \
#   GIT_NAME="Jordan Gaston" GIT_EMAIL="you@example.com" \
#   RECOVERY_PUBKEY="$(cat ~/.ssh/recovery_ed25519.pub)" \
#   bash hetzner-box-setup.sh
# Each line below uses your env value if set, else the placeholder default.
GH_REPO_URL="${GH_REPO_URL:-https://github.com/YOURUSER/knowledge.git}"   # empty PRIVATE repo
GIT_NAME="${GIT_NAME:-Your Name}"
GIT_EMAIL="${GIT_EMAIL:-you@example.com}"
# RECOVERY_PUBKEY = contents of ~/.ssh/recovery_ed25519.pub (a public key; safe).
# Your PRIMARY key is already injected by Hetzner at create time; this adds a
# backup key so a single lost/corrupted key never locks you out of the box.
RECOVERY_PUBKEY="${RECOVERY_PUBKEY:-ssh-ed25519 AAAA...replace-me... recovery-key}"

# ---- 0b. Trust the recovery SSH key for root -------------------------------
if [[ "$RECOVERY_PUBKEY" == ssh-* && "$RECOVERY_PUBKEY" != *"AAAA...replace-me..."* ]]; then
  install -d -m 700 /root/.ssh
  grep -qxF "$RECOVERY_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null \
    || printf '%s\n' "$RECOVERY_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "Recovery SSH key trusted for root."
else
  echo "WARN: RECOVERY_PUBKEY not set — skipping. Paste your recovery .pub and re-run to add it." >&2
fi

# ---- 1. Service user + base packages ---------------------------------------
useradd --create-home --shell /bin/bash orca
apt-get update
apt-get install -y git curl wget file jq

# ---- 2. Node 24 (Open Knowledge + Claude Code both run on it) --------------
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

# ---- 3. GitHub CLI (OK's git sync auth) ------------------------------------
mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
apt-get update && apt-get install -y gh

# ---- 4. Electron/Xvfb libraries the Orca AppImage needs (Ubuntu 24.04 t64) --
apt-get install -y \
  xvfb zlib1g-dev ca-certificates libfuse2t64 \
  libgtk-3-0t64 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libgbm1 libasound2t64 \
  libxtst6 libcups2t64 libdrm2 libxkbcommon0 libpango-1.0-0 libcairo2 libatspi2.0-0t64 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 \
  libxcb-dri3-0 libxss1
# (On Ubuntu 20.04/22.04 drop the six `t64` suffixes — see headless-linux-server.md)

# ---- 5. Tailscale (private link; --ssh lets you admin over the tailnet) -----
curl -fsSL https://tailscale.com/install.sh | sh
###PAUSE### approve the auth URL in your browser.
tailscale up --ssh
TS_IP="$(tailscale ip -4)"
TS_NAME="$(tailscale status --json | grep -m1 '"DNSName"' | cut -d'"' -f4 | sed 's/\.$//')"
echo "Box tailnet IP: ${TS_IP}   name: ${TS_NAME}"

# ---- 6. Claude Code (agents Orca launches run through it) -------------------
npm install -g @anthropic-ai/claude-code

# ---- 7. Open Knowledge -----------------------------------------------------
npm install -g @inkeep/open-knowledge
sudo -u orca bash -eu <<OK
cd ~
ok init knowledge >/dev/null 2>&1 || { mkdir -p knowledge && cd knowledge && ok init; }
cd ~/knowledge
mkdir -p .ok/local
cat > .ok/config.yml <<YAML
server:
  port: 8080
  externalUrl: https://${TS_NAME}
YAML
cat > .ok/local/config.yml <<YAML
server:
  allowExternal: true
  idleShutdown: "off"
autoSync:
  mode: full
YAML
git config --global user.name  "${GIT_NAME}"
git config --global user.email "${GIT_EMAIL}"
OK

# OK service
cat > /etc/systemd/system/openknowledge.service <<'UNIT'
[Unit]
Description=OpenKnowledge server
After=network-online.target
[Service]
User=orca
WorkingDirectory=/home/orca/knowledge
ExecStart=/usr/bin/env ok start
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

# ---- 8. Orca headless runtime (x86 AppImage; CX53 is Intel) ----------------
mkdir -p /opt/orca
curl -L https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage \
  -o /opt/orca/orca-linux.AppImage
chown root:root /opt/orca /opt/orca/orca-linux.AppImage
chmod 755 /opt/orca /opt/orca/orca-linux.AppImage

cat > /etc/systemd/system/orca-serve.service <<UNIT
[Unit]
Description=Orca runtime server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=simple
User=orca
WorkingDirectory=/home/orca
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/opt/orca/orca-linux.AppImage serve --port 6768 --pairing-address ${TS_IP}
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now openknowledge.service orca-serve.service

cat <<NEXT

================= NEXT: three interactive steps as the 'orca' user =============
Run:  sudo -u orca -i     then inside that shell:

  1. gh auth login                          # GitHub push access for OK sync
     cd ~/knowledge
     git remote add origin ${GH_REPO_URL}
     git branch -M main && git add -A && git commit -m "knowledge base" && git push -u origin main
     printf '\nautoSync:\n  mode: full\n' >> .ok/local/config.yml   # already set, harmless

  2. claude                                 # then /login  (one-time Claude Code auth)

  3. /opt/orca/orca-linux.AppImage skills install --skill orca-cli --skill orchestration --agent claude-code

Then back as root:  systemctl restart openknowledge

Publish OK's editor privately on the tailnet (needs HTTPS enabled once in the
Tailscale admin console):   sudo -u orca tailscale serve --bg 8080

Get the Orca pairing URL for your laptop + phone:
  journalctl -u orca-serve -o cat | grep -m1 'Pairing URL'
===============================================================================
NEXT
