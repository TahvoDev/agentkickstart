# agentkickstart

> **Prototype / experimental.** A work in progress, subject to breaking changes
> without notice. **Not** intended for production use. Back up anything important
> and expect rough edges. Licensed AGPL-3.0 (see `LICENSE`).

A bootc image (plus its containers) that turns a PC into a self-contained **agent
box**: Paseo + OpenCode agents on a real XFCE desktop (Xvfb + noVNC), reached
over your LAN or a Tailscale tailnet, with credentials brokered by a local Agent
Vault. The host is immutable and deliberately tiny; the desktop and the Agent
Vault run as containers, and the claim proxy (the *gate*) is a static binary
baked into the image.

The image is **generic**: no user, key or password is baked in. Identity is
created at first boot — a console wizard sets up the admin user + SSH key, then a
one-time browser *claim* creates the vault owner and prints the passwords (and
the disk recovery key) once.

## Quickstart

You need the ISO; everything else is automatic. ~15 min of install time.

1. **Download `install.iso`** from the rolling
   [**edge** release](https://github.com/TahvoDev/agentkickstart/releases/tag/edge).
   (Or build it locally — see [Building it yourself](#building-it-yourself).)

2. **Flash it to a USB stick:**

   ```sh
   sudo dd if=install.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

3. **Boot the target PC from the stick.** The installer lists the internal disks
   (boot USB / removable media filtered out), asks you to **type `ERASE`**, then
   erases that disk and installs unattended. It binds the encrypted root to the
   TPM and leaves a recovery key in `/root/recovery-key.txt`. Reboot.

4. **First boot (on the console).** `agentbox setup` runs: it creates the admin
   user and asks for an SSH key (paste a key or a GitHub username), then starts
   the Agent Vault and the gate and prints a **claim URL, one-time code and QR**.

5. **Claim it (in a browser).** Open the URL, compare the certificate
   fingerprint with the one on the console, and enter the code plus an owner
   email/password. The result page shows the vault URL, the desktop + Paseo
   passwords, and the **disk recovery key** — save them.

6. **Use it.** The desktop is up. Check the box with:

   ```sh
   ssh <user>@<box> sudo agentbox status
   ```

No LAN route (client isolation)? Do step 5 on the console instead:
`sudo agentbox setup --console`.

## What you need

- An x86_64 PC with **UEFI** and a **TPM** (the install aborts without one), one
  internal disk (it gets erased), and a network.
- The agent package must be pullable without interactive auth — make the
  `agentbox-agent` GHCR package public.
- Optional: a Tailscale auth key **tagged `tag:agentbox`** (allowed to mint HTTPS
  certs in your tailnet ACLs), a **fine-grained, repo-scoped** GitHub token, and a
  **spend-limited** Anthropic key. The box brokers these, so a key's blast radius
  is whatever the key itself allows.

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

## How it works

Three artifacts, one repo:

| Artifact | Source | Where it goes |
| --- | --- | --- |
| **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | pulled by the box at runtime |
| **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | installed by the installer ISO |
| **installer ISO** (`output/install.iso`) | `os/iso/` | booted to install the OS image |

The claim UI / vault proxy (the *gate*, `gate/`) is not an artifact: it is a tiny
static Go binary compiled into the OS image.

The host OS image is tiny — podman + systemd + quadlets. The XFCE desktop and the
Agent Vault + Tailscale run as **containers**. Everything the box updates from is
a **container ref**, so a registry is the hinge: no registry → it installs but
can't update, and the agent container can't be pulled.

Static payload lives under `/usr` (immutable, versioned). `/etc` holds only the
durable bootstrap token (`/etc/agentbox/bootstrap.env`); everything else is
runtime state — secrets are re-fetched into `/run/agentbox/secrets` (tmpfs) on
every boot, and live claim state lives in `/run/agentbox`.

### Layout

```
agent/                     the agent desktop container image
  Containerfile
  opencode.json            MCP servers (also the egress source of truth)
  nginx.conf
  start-agent.sh
gate/                      the gate source: one-time claim UI, then a reverse
  main.go                  proxy to the vault; also renders the QR for
  page.go                  `agentbox setup`. Compiled into the OS image.
os/                        the bootc OS image
  Containerfile            builds the gate + COPYs the payload + enables units
  iso/                     bootc-generic-iso installer (Anaconda + picker + kickstart)
  system/                  the host payload, one file per source of truth (vendor /usr)
    usr/bin/agentbox              the one CLI (setup/finalize/up/status/authorize)
    usr/libexec/agentbox/agentbox-egress  derives the LAN allowlist from the MCP config
    usr/lib/systemd/system/       firewall / vault / provision / selinux / claim units
    usr/lib/tmpfiles.d/           creates the volume/config dirs with owners
    usr/lib/bootc/install/        bootc install defaults (root fs)
    usr/share/containers/systemd/ quadlets (agentbox, agent-vault, tailscale, net)
    usr/share/agentbox/           static firewall policy, MCP config, tailscale serve config
build.sh                   build + push the images; build the installer ISO
deploy.sh                  dev loop: build+push :dev and `bootc switch` a live box
```

## Building it yourself

```sh
OWNER=youruser ./build.sh agent        # build + push the agent image
OWNER=youruser ./build.sh os           # build + push the OS image (includes the gate)
OWNER=youruser ./build.sh installer    # -> ./output/install.iso
```

The ISO build needs **rootful podman + sudo** — the builder has to mount
devtmpfs, so rootless podman fails with `mount: /dev: permission denied`;
`build.sh` re-runs itself under `sudo`. Don't build from inside an unprivileged
container for the same reason.

CI (`.github/workflows/build.yml`) builds and pushes the agent + OS images on
`main`, keyless-signs them, and republishes `install.iso` on the rolling `edge`
release. Push to GHCR needs **`packages: write`**, which CI's built-in
`GITHUB_TOKEN` has; the local GitHub App token can log in but **cannot create
packages**.

Fast loop on a running box: `OWNER=youruser ./deploy.sh os <ssh-target>`
rebuilds the OS image, pushes `:dev`, and `bootc switch`es the box. Everything
under `os/` and `gate/` — CLI, units, quadlets, firewall, gate — comes along in
the image, so there is no rsync path. `deploy.sh agent` just pushes and restarts
the one container. Updates: `bootc upgrade` (OS) + `podman-auto-update.timer`
(agent).

### Testing the installer in a VM

```sh
LOCAL=1 ./build.sh installer     # offline build (still needs sudo); -> output/install.iso
```

`%post` needs a TPM, so run QEMU with `swtpm`; no `/dev/kvm` is fine, just slow.
Boot the ISO with the kernel/initrd from the ISO (direct `-kernel`/`-append`, or
the ISO's own menu), a blank virtio disk and serial console. Under `LOCAL=1` the
whole claim path still works — the gate is baked into the OS image — but the
**desktop** can't start: the agent image isn't pullable and `bootc upgrade`
points at `localhost`. That's the registry gap, not a bug; a real
`OWNER=<ns> ./build.sh` deploy closes it.

## Notes for maintainers

### Installer

- Uses the **`bootc-generic-iso`** image type: the kernel + EFI tree come from
  the `os/iso/` installer container, so it builds on a hosted Ubuntu runner. The
  older `bootc-installer` type needs a native Fedora host (its `grub2.iso` stage
  reads the shim from the build root's `/boot/efi`, and Fedora 44 moved it to
  `/usr/lib/efi`).
- The **erase-and-go disk pick** is a systemd unit (`agentbox-pick.service`,
  `Before=anaconda.service`) that prompts on the console, then rewrites the
  kickstart with the chosen disk. Kickstart `%pre` + `%include` can't do this:
  `%include` is expanded at parse time, before `%pre` runs.
  `autopart --fstype=xfs --encrypted --passphrase=<random>` keeps Anaconda
  non-interactive; `%post` enrolls the TPM (PCR 7) and writes the recovery key.
- **UI**: we boot the text installer (`inst.text`). Anaconda's Cockpit-based Web
  UI (`inst.graphical`) exists but has no SSH-key field either.

### SSH keys: no install-time prompt (by design)

bootc's SSH-key mechanisms are all CLI-flag or pre-config (the install flag,
systemd credentials/SMBIOS, cloud-init/Ignition, tmpfiles), and Anaconda has no
SSH-key field. So the ISO stays generic and the key is added **after** install:
`agentbox setup` prompts for it, installs it for the sudo user, and offers to
disable password SSH. `agentbox authorize add` adds more later.

### SELinux

The box runs SELinux **enforcing**. The one thing needing care is the Tailscale
container opening `/dev/net/tun`: `container_t` has no tun access by default, so
`agentbox-selinux.service` sets the `container_use_devices` boolean — a scoped
relaxation (the device cgroup still gates it), not a blanket label disable. The
installer environment boots permissive (`enforcing=0`); the installed box
enforces regardless.

## Back up

`/var/lib/agent-vault` and `/etc/agent-vault/master.env`, plus the recovery key.

## Known gaps

- The TPM keyslot is bound at **PCR 7 (Secure Boot state)**: a firmware/Secure
  Boot change invalidates it — the recovery key is the way back in.
- **Hostname** is baked as `agentbox`; change it with `hostnamectl` if you like
  (Tailscale names the box on the tailnet via `TS_HOSTNAME`).
- A Chromium-in-container escape, or misuse within what an API key allows, is
  out of scope.
