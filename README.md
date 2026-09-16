# box

Provision an always-on Hetzner server that runs a **Remote Orca Server**, **Open
Knowledge** (with GitHub auto-sync), and **Claude Code** — and drive it from both
your laptop and your phone over Tailscale.

## What you get

- A Hetzner box that **owns the Orca runtime**. Your laptop and phone pair into it
  as clients and share the same live agent sessions.
- **Claude Code** installed on the box, so agents run on the server, not your laptop.
- **Open Knowledge** running as a service, auto-committing and pushing to a private
  GitHub repo — your knowledge base survives total loss of the box.
- **Tailscale** ties everything together on a private network. Nothing is exposed
  to the public internet.

```
  laptop (Orca desktop) ─┐
                         ├─ Tailscale ──► Hetzner box ── orca serve (runtime)
  phone  (Orca mobile) ──┘                            ├─ Open Knowledge ─► GitHub
                                                       └─ Claude Code (agents)
```

## Prerequisites

Create these accounts first — all have free tiers except the Hetzner server itself:

| Account | Used for |
|---|---|
| [Hetzner Cloud](https://console.hetzner.com) | The server (~$35/mo for a CX53) |
| [GitHub](https://github.com) | Backing store for the knowledge base |
| [Tailscale](https://tailscale.com) | Private network between box, laptop, phone |
| [Anthropic](https://claude.ai) | Claude Code sign-in (Pro/Max or API key) |

You also need a laptop (macOS commands are shown; the Tailscale and `ssh`/`git`
tooling is identical on Linux and Windows) and, optionally, a phone.

---

## Part A — Laptop prep

### 1. Install Tailscale and sign in
```bash
brew install --cask tailscale     # macOS; see tailscale.com/download for other OSes
```
Open the app, sign in, and approve the VPN prompt. In the
[admin DNS page](https://login.tailscale.com/admin/dns), enable **MagicDNS** and
**HTTPS Certificates** (the latter lets the box publish the Open Knowledge editor
over HTTPS). Confirm it works:
```bash
tailscale status      # your machine should appear with a 100.x address
```

### 2. Generate two SSH keys
A **primary** key for daily use and a **recovery** key you store offline, so losing
your laptop never locks you out of the box.
```bash
# Primary — set a passphrase when prompted
ssh-keygen -t ed25519 -C "primary" -f ~/.ssh/id_ed25519
ssh-add --apple-use-keychain ~/.ssh/id_ed25519

# Recovery — keep its PRIVATE half only in a password manager
ssh-keygen -t ed25519 -C "recovery" -f ~/.ssh/recovery_ed25519
```
Add to `~/.ssh/config` so the key loads automatically:
```
Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
```
Back up the private key `~/.ssh/id_ed25519` and its passphrase to a password
manager, plus one encrypted offline copy. **Never** sync a private key unencrypted
to any cloud. Public keys (`*.pub`) are safe to share — only those go on the box.

## Part B — GitHub repo for the knowledge base

Create an **empty private repo** named `knowledge`. Open Knowledge pushes to it on
its own once the box is running. Note the clone URL, e.g.
`https://github.com/YOURUSER/knowledge.git`.

## Part C — Provision the Hetzner box

In the [Hetzner Console](https://console.hetzner.com), add a server:

- **Location:** closest to you (lower latency for interactive sessions).
- **Image:** Ubuntu 24.04.
- **Type:** **CX53** — 16 vCPU / 32 GB / NVMe (x86 Intel). *(The cheaper Arm64 CAX41
  works too but is EU-region-only and often sold out; if you pick Arm, change the
  AppImage URL in the script from `orca-linux.AppImage` to `orca-linux-arm64.AppImage`.)*
- **SSH keys:** add **both** your primary and recovery public keys.
- **Backups** (optional, ~20% of the server price): one-click whole-VM restore.

The included NVMe disk is ample — you do not need a Volume.

## Part D — Run the setup script

SSH in and clone this repo:
```bash
ssh root@<box-ip>
git clone https://github.com/YOURUSER/box.git && cd box
```
Run the script with your three values as environment variables:
```bash
GH_REPO_URL="https://github.com/YOURUSER/knowledge.git" \
GIT_NAME="Your Name" \
GIT_EMAIL="you@example.com" \
bash hetzner-box-setup.sh
```
It installs Node, Tailscale, Claude Code, Open Knowledge, and the Orca runtime, and
starts two services. It **pauses once** for Tailscale sign-in — use the same account
as your laptop so the box joins the same tailnet.

When it finishes, run the interactive steps it prints, as the `orca` service user:
```bash
sudo -u orca -i
  gh auth login                       # GitHub push access for the knowledge base
  cd ~/knowledge
  git remote add origin "$GH_REPO_URL"
  git branch -M main && git add -A && git commit -m "knowledge base" && git push -u origin main
  claude                              # then /login — one-time Claude Code auth
  /opt/orca/orca-linux.AppImage skills install --skill orca-cli --skill orchestration --agent claude-code
  exit
systemctl restart openknowledge
sudo -u orca tailscale serve --bg 8080   # publish the OK editor on your tailnet
```
Get the Orca pairing URL for your clients:
```bash
journalctl -u orca-serve -o cat | grep -m1 'Pairing URL'
# → orca://pair?code=...
```

## Part E — Connect your laptop

1. Ensure Tailscale is running on the laptop.
2. In Orca desktop ([download](https://www.onorca.dev/download)), connect to a
   **Remote Orca Server** and paste the pairing URL.
3. Add a code repo **on the server**, create a worktree, and launch a Claude Code
   agent. It runs on the box; your laptop is the window into it.

## Part F — Connect your phone

1. Install the Tailscale app, sign into the same account, and connect.
2. In the Orca mobile app, add a **server / remote** target and enter the same
   pairing code (or scan the QR if your build shows one).
3. Monitor agents and send follow-ups from your phone.

## Part G — Verify

- **Shared session:** start an agent on the laptop; it appears on the phone.
- **Knowledge sync:** edit a doc at `https://<box>.<your-tailnet>.ts.net`; the commit
  lands in your GitHub `knowledge` repo within about a minute. Agents on the box
  reach Open Knowledge at `http://localhost:8080/mcp`.
- **Keys:** `ssh` in once with each key to confirm both work.

---

## Configuration

The script reads three environment variables, each with a placeholder default:

| Variable | Meaning |
|---|---|
| `GH_REPO_URL` | Clone URL of your empty private `knowledge` repo |
| `GIT_NAME` | Commit author name for the knowledge base |
| `GIT_EMAIL` | Commit author email |

SSH keys are added in the Hetzner console, not the script. Set the variables at
runtime (as in Part D) rather than editing the file, so a fork keeps no personal data.

## Ports

| Port | Service | Reached via |
|---|---|---|
| 6768 | Orca runtime | Tailscale (laptop + phone pairing) |
| 8080 | Open Knowledge | `tailscale serve` HTTPS, or `localhost` for on-box agents |

## Known limitations

- **No push notifications** to your phone from a headless server. You can watch and
  assign work live, but the phone will not alert you when an agent finishes.
- **Phone-to-server pairing** is newer than phone-to-desktop pairing; expect rougher
  edges.
- The server-side steps follow Orca's official
  [headless Linux server guide](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md).
  The desktop and mobile client menu labels may differ slightly by version.

## Recovery and backups

- **Data:** Open Knowledge auto-pushes to GitHub, so the knowledge base is safe even
  if the box dies. Push your code repos regularly for the same protection.
- **The box:** it is reproducible from this script — re-run it on a fresh server.
  For a one-click restore that also preserves Orca session state and paired devices,
  enable Hetzner Cloud Backups.
- **Lockout safety net:** Tailscale SSH, the Hetzner console rescue, and your recovery
  key each get you back in if the primary key is lost.

## Cost

Roughly **$35/mo** for the CX53, plus about **$7/mo** if you enable Hetzner Backups.
Everything else runs on free tiers.
