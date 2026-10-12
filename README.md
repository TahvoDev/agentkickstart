# agentkickstart

A bootc image (plus its agent container) that turns a PC into a self-contained
agent box: Paseo + OpenCode agents on a real XFCE desktop (Xvfb + noVNC),
reached over Tailscale, with credentials brokered by a local Agent Vault. The
host is immutable and deliberately tiny; the desktop and both brokers run as
containers.

Three artifacts, one repo:

| Artifact | Source | Where it goes |
| --- | --- | --- |
| **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | pulled by the box at runtime |
| **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | installed by the installer ISO |
| **installer ISO** (`output/install.iso`) | `os/installer.toml` | booted to install the OS image |

## Layout

```
agent/                     the agent desktop container image
  Containerfile
  opencode.json            MCP servers (also the egress source of truth)
  nginx.conf
  start-agent.sh
os/                        the bootc OS image
  Containerfile            packages + COPY the payload + enable units
  installer.toml           installer blueprint (admin user, kickstart: TPM + recovery)
  system/                  the host payload, one file per source of truth
    usr/bin/agentbox           the one CLI (setup/up/status/allow/...)
    usr/bin/agentbox-egress    derives the LAN allowlist from the MCP config
    usr/lib/tmpfiles.d/        creates the volume/config dirs with owners
    etc/containers/systemd/    quadlets (agentbox, agent-vault, tailscale, net)
    etc/systemd/system/        firewall / vault-init / provision units
    etc/agentbox/firewall.nft  the container egress policy
    etc/tailscale/serve/       tailnet HTTPS routes
build.sh                   build + push both images, then the installer ISO
```

## Build and install

```sh
# 1. edit os/installer.toml -> admin username + SSH public key
# 2. build and publish both images (the box pulls these at runtime)
OWNER=youruser ./build.sh agent
OWNER=youruser ./build.sh os
# 3. build the installer ISO (local only, no registry)
./build.sh installer                     # -> ./output/install.iso
```

Boot `output/install.iso`, pick the target disk and tick **encrypt my data** in
the Anaconda UI. `%post` then binds the encrypted root to the TPM, writes the
recovery key to `/root/recovery-key.txt`, and you reboot into the box. The OS
updates itself with `bootc upgrade`; the agent image updates via
`podman-auto-update.timer`.

### Requirements for the build host

- **podman**, and **`sudo`** for the `installer` step. The `image-builder`
  container mounts `devtmpfs` and writes an OS image, so it must run *rootful*
  (`build.sh` re-runs it under `sudo` via `$SUDO`). Rootless podman cannot do
  this — a rootless run fails with `mount: /dev: permission denied`.
- **No SELinux required.** On hosts without it (e.g. Ubuntu) `build.sh` shims
  `chcon`/`restorecon` out of the builder, which otherwise fails trying to
  relabel its store (`chcon: … Operation not permitted`).
- The `agent`/`os` steps push to `$REGISTRY/$OWNER`; the box pulls the agent
  image from there at runtime, and `bootc upgrade` pulls the OS image.
- `installer` embeds the OS image and records its ref as the installed box's
  update source, so run `./build.sh os` first — it pulls the pushed image by
  default. For an **offline smoke test**, `LOCAL=1 ./build.sh installer` builds
  the OS image from local storage instead (it installs fine, but `bootc upgrade`
  is left pointing at `localhost` and won't work).
- Don't run the build from inside an unprivileged container: the `devtmpfs`
  mount needs real root.

## First boot

```sh
ssh you@agentbox            # over the LAN
sudo agentbox setup         # asks for the 3 keys, does the rest
```

The disk encryption, TPM binding and recovery key were already done by the
installer (`/root/recovery-key.txt` on the target). `setup` stores the Anthropic
key, GitHub token and Tailscale auth key in the local vault, then starts
Tailscale and the agent desktop. It prints the desktop / Paseo / vault-owner
passwords **once** — save them.

## Daily use

```sh
sudo agentbox up|status|logs|shell     # sync secrets, restart, inspect
sudo agentbox login|logout|av <args>   # vault owner session / CLI
sudo agentbox allow <ip|cidr>...       # extra hosts MCP config can't express
sudo agentbox allow clear              # revoke all manual entries
```

### Reaching a LAN/tailnet service from an MCP

Point the MCP at it — no extra step. Before the firewall comes up,
`agentbox-egress` reads the enabled MCPs in `opencode.json`, pulls every
LAN/tailnet address out of each one's `url`, `environment` and command
arguments, resolves url hostnames, and opens exactly those. For anything a
config can't express, use `sudo agentbox allow`.

The host itself and mDNS `.local` names stay unreachable by design.

## URLs (tailnet only)

| URL | What |
| --- | --- |
| `https://agentbox.<tailnet>.ts.net` | Paseo |
| `https://agentbox.<tailnet>.ts.net:8443` | desktop (login user `agent`) |

## Back up

`/var/lib/agent-vault` and `/etc/agent-vault/master.env`.

## Before you build

- The Tailscale auth key must be **tagged `tag:agentbox`**, and that tag must be
  allowed to mint HTTPS certs in your tailnet ACLs.
- The GitHub token should be **fine-grained and repo-scoped**; the Anthropic key
  should have a **spend limit**. The box brokers these, so a key's blast radius
  is whatever the key itself allows.
- The registry namespace must exist and (for the box to pull) the agent image
  must be pullable without interactive auth.

## Known gaps

- **Hostname**: set it at install time (the installer's hostname field, or
  `hostnamectl`); it is deliberately not baked into the image.
- **TPM unlock and firmware updates**: root is bound to PCR 7 (Secure Boot
  state), so a firmware/Secure Boot change can invalidate the TPM keyslot — the
  recovery key written by the installer is the way back in. Keep it safe.
- A Chromium-in-container escape, or misuse within what an API key allows, is
  out of scope.
