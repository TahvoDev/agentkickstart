# agentkickstart

A bootc image (plus its agent container) that turns a PC into a self-contained
agent box: Paseo + OpenCode agents on a real XFCE desktop (Xvfb + noVNC),
reached over Tailscale, with credentials brokered by a local Agent Vault. The
host is immutable and deliberately tiny; the desktop and both brokers run as
containers.

Two artifacts, one repo:

| Artifact | Source | Where it goes |
| --- | --- | --- |
| **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | pulled by the box at runtime |
| **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | flashed to a disk by bootc-image-builder |

## Layout

```
agent/                     the agent desktop container image
  Containerfile
  opencode.json            MCP servers (also the egress source of truth)
  nginx.conf
  start-agent.sh
os/                        the bootc OS image
  Containerfile            packages + COPY the payload + enable units
  config.toml              bootc-image-builder install config (user + SSH key)
  system/                  the host payload, one file per source of truth
    usr/bin/agentbox           the one CLI (setup/up/status/allow/...)
    usr/bin/agentbox-egress    derives the LAN allowlist from the MCP config
    usr/lib/tmpfiles.d/        creates the volume/config dirs with owners
    etc/containers/systemd/    quadlets (agentbox, agent-vault, tailscale, net)
    etc/systemd/system/        firewall / vault-init / provision units
    etc/agentbox/firewall.nft  the container egress policy
    etc/tailscale/serve/       tailnet HTTPS routes
build.sh                   build + push the agent and OS images, then a disk
```

## Build and flash

```sh
# 1. edit os/config.toml -> admin username + SSH public key
# 2. build and publish both images
OWNER=youruser ./build.sh agent
OWNER=youruser ./build.sh os

# 3. turn the OS image into a flashable disk (writes ./output/image/disk.raw)
OWNER=youruser ./build.sh disk
```

Then flash `output/image/disk.raw` to the target disk and boot. The box updates
the OS itself with `bootc upgrade`; the agent image updates via
`podman-auto-update.timer`.

## First boot

```sh
ssh you@agentbox            # over the LAN
sudo agentbox setup         # asks for the 3 keys, does the rest
sudo systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/root
```

`setup` stores the Anthropic key, GitHub token and Tailscale auth key in the
local vault, then starts Tailscale and the agent desktop. It prints the desktop
/ Paseo / vault-owner passwords **once** — save them.

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

- **Disk encryption / TPM**: the previous Ignition build sealed the root with
  the TPM. In the bootc flow this is an install-time choice — pass the
  filesystem/encryption option to bootc-image-builder (or enroll
  `systemd-cryptenroll` right after install). Confirm the exact current flag
  against your bootc-image-builder version before relying on it.
- **Hostname**: set it at install time (`--hostname` on the installer, or
  `hostnamectl`); it is deliberately not baked into the image.
- A Chromium-in-container escape, or misuse within what an API key allows, is
  out of scope.
