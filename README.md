# agentkickstart

> **Prototype / experimental.** A work in progress, subject to breaking changes
> without notice. **Not** intended for production use. Back up anything important
> and expect rough edges. Licensed AGPL-3.0 (see `LICENSE`).

A bootc image (plus its containers) that turns a PC into a self-contained agent
box: Paseo + OpenCode agents on a real XFCE desktop (Xvfb + noVNC), reached over
your LAN or a Tailscale tailnet, with credentials brokered by a local Agent
Vault. The host is immutable and deliberately tiny; the desktop and the brokers
run as containers.

The image is **generic**: no user, key or password is baked in. Identity is
created at first boot — a small console wizard sets up the admin user + SSH key,
then a one-time browser *claim* creates the vault owner and prints the
passwords (and the disk recovery key) once.

Four artifacts, one repo:

| Artifact | Source | Where it goes |
| --- | --- | --- |
| **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | pulled by the box at runtime |
| **gate image** (`ghcr.io/OWNER/agentbox-gate`) | `gate/` | the TLS claim UI + vault reverse proxy |
| **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | installed by the installer ISO |
| **installer ISO** (`output/install.iso`) | `os/iso/` | booted to install the OS image |

## Layout

```
agent/                     the agent desktop container image
  Containerfile
  opencode.json            MCP servers (also the egress source of truth)
  nginx.conf
  start-agent.sh
gate/                      the gate container: one-time claim UI, then a
  main.go                  reverse proxy to the vault; also renders the QR
  page.go                  code for `agentbox setup`
  Containerfile
os/                        the bootc OS image
  Containerfile            COPY the payload + enable units
  iso/                     bootc-generic-iso installer (Anaconda + picker + kickstart)
  system/                  the host payload, one file per source of truth (vendor /usr)
    usr/bin/agentbox              the one CLI (setup/finalize/up/status/authorize)
    usr/libexec/agentbox/agentbox-egress  derives the LAN allowlist from the MCP config
    usr/lib/tmpfiles.d/           creates the volume/config dirs with owners
    usr/lib/systemd/system/       firewall / vault / provision / selinux / claim units
    usr/share/containers/systemd/ quadlets (agentbox, agent-vault, gate, tailscale, net)
    usr/share/agentbox/           static firewall policy, MCP config, tailscale serve config
build.sh                   build + push the images; build the installer ISO
deploy.sh                  dev loop: build+push :dev and `bootc switch` a live box
```

Static payload lives under `/usr` (immutable, versioned). `/etc` holds only the
durable bootstrap token (`/etc/agentbox/bootstrap.env`); everything else is
runtime state: secrets are re-fetched into `/run/agentbox/secrets` (tmpfs) on
every boot, and live claim state lives in `/run/agentbox`.

## Install

CI publishes the ISO — no local build needed.

1. Download `install.iso` from the rolling **edge** release, or build it:

   ```sh
   LOCAL=1 ./build.sh installer     # -> ./output/install.iso (needs podman + sudo)
   ```

2. Flash it to a USB stick:

   ```sh
   sudo dd if=install.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

3. Boot the stick. The installer lists the internal disks (boot USB and
   removable media filtered out), asks you to **type `ERASE`** to confirm, then
   erases that disk and installs the OS image unattended. `%post` binds the root
   LUKS to the TPM (PCR 7) and writes a recovery key to `/root/recovery-key.txt`
   on the installed system. Reboot into the box and continue at **First boot**.

### CI (pre-release)

`.github/workflows/build.yml` has two jobs on push to `main` (or manual
dispatch):

- **images** (hosted `ubuntu-latest`) builds and pushes **agent**, **gate** and
  **OS** images to your GHCR namespace, then keyless-signs and self-verifies
  them. It uses the workflow's built-in `GITHUB_TOKEN` (`packages: write`) — no
  PAT. While testing it tags `:edge`; promote a digest to `:latest` and/or flip
  the packages public at release (the box pulls the gate + agent images without
  auth, so those packages must be public for an unauthenticated install).
- **installer** builds `install.iso` with the `bootc-generic-iso` type (kernel +
  EFI come from the `os/iso` installer container, so it builds anywhere with
  podman + sudo) and replaces the `install.iso` asset on the rolling `edge`
  release.

Once installed, update the OS with `bootc upgrade`; the agent image auto-updates
via `podman-auto-update.timer`.

### Building / developing locally (maintainers)

```sh
OWNER=youruser ./build.sh agent        # build + push the agent image
OWNER=youruser ./build.sh gate         # build + push the gate image
OWNER=youruser ./build.sh os           # build + push the OS image
OWNER=youruser ./build.sh installer    # -> ./output/install.iso
```

The fast loop once a box is running: `OWNER=youruser ./deploy.sh os <ssh-target>`
rebuilds the OS image, pushes `:dev`, and `bootc switch`es the box (then
reboots). Everything under `os/` — CLI, units, quadlets, firewall — comes along
in the image, so there is no rsync path. `deploy.sh agent` / `deploy.sh gate`
just push and restart the one container.

## First boot

The box has no user yet. On the console, `agentbox-firstboot.service` runs
`agentbox setup`, which:

1. creates the admin user and installs your SSH key (paste a key or a GitHub
   username), offering to disable password SSH;
2. starts the Agent Vault and the gate, then prints a claim URL + one-time code
   (and a QR code) on the console.

Open the URL in a browser, compare the certificate fingerprint with the console,
and enter the code plus an owner email/password. The browser claim finalizes the
host: creates the vault owner and both vaults, mints the brokered tokens, stores
the desktop/Paseo passwords, and starts the agent desktop. The result page shows
the vault URL, the desktop + Paseo passwords, and the **disk recovery key** —
save them.

No LAN route (client isolation)? Use `sudo agentbox setup --console` to create
the owner on the console instead.

## Daily use

```sh
sudo agentbox up|status|logs         # sync secrets, restart, inspect
sudo agentbox passphrase             # print the desktop + Paseo passwords
sudo agentbox authorize add          # add another SSH key for the admin user
sudo agentbox setup-code             # issue a fresh one-time claim code
```

Credentials and service rules live in the box's Agent Vault; manage them in its
web UI. The agent only ever gets placeholder env values — Agent Vault injects the
real ones at its outbound proxy.

### Reaching a LAN/tailnet service from an MCP

Point the MCP at it — no extra step. Before the firewall comes up,
`agentbox-egress` reads the enabled MCPs in `opencode.json`, pulls every
LAN/tailnet address out of each one's `url`, `environment` and command
arguments, resolves url hostnames, and opens exactly those. The host itself and
mDNS `.local` names stay unreachable by design.

## Before you build

- The Tailscale auth key must be **tagged `tag:agentbox`**, and that tag must be
  allowed to mint HTTPS certs in your tailnet ACLs.
- The GitHub token should be **fine-grained and repo-scoped**; the Anthropic key
  should have a **spend limit**. The box brokers these, so a key's blast radius
  is whatever the key itself allows.
- The gate + agent packages must be pullable without interactive auth (make them
  public).
- The disk is bound to the TPM at PCR 7 (Secure Boot state); a firmware/Secure
  Boot change invalidates the TPM keyslot — the recovery key is the way back in.

## Back up

`/var/lib/agent-vault` and `/etc/agent-vault/master.env`, plus the recovery key.

## Known gaps

- **Hostname** is baked as `agentbox`; change it with `hostnamectl` if you like
  (Tailscale names the box on the tailnet via `TS_HOSTNAME`).
- A Chromium-in-container escape, or misuse within what an API key allows, is
  out of scope.
