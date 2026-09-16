# box

Provisioning script for a Hetzner always-on box that runs a **Remote Orca Server**,
**Open Knowledge** (with GitHub auto-sync), and **Claude Code** — reachable from a
laptop and phone over Tailscale.

## Usage

1. Read the header of [`hetzner-box-setup.sh`](hetzner-box-setup.sh) and do the
   laptop prep (SSH keys, Tailscale).
2. Fill in the vars at the top: `GH_REPO_URL`, `GIT_NAME`, `GIT_EMAIL`, `RECOVERY_PUBKEY`.
3. Create a Hetzner **CX53** (Ubuntu 24.04, 32 GB), add your primary SSH key.
4. On the box: `bash hetzner-box-setup.sh`, then run the interactive steps it prints.

The script is idempotent-ish and self-documented. No secrets belong in it — only
public keys and non-sensitive config.
