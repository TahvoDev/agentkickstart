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
| **installer ISO** (`output/install.iso`) | `os/iso/` | booted to install the OS image |

## Layout

```
agent/                     the agent desktop container image
  Containerfile
  opencode.json            MCP servers (also the egress source of truth)
  nginx.conf
  start-agent.sh
os/                        the bootc OS image
  Containerfile            COPY the payload + enable units
  iso/                     bootc-generic-iso installer container (Anaconda + kickstart)
  system/                  the host payload, one file per source of truth
    usr/bin/agentbox           the one CLI (setup/up/status/authorize/allow/...)
    usr/bin/agentbox-egress    derives the LAN allowlist from the MCP config
    usr/lib/tmpfiles.d/        creates the volume/config dirs with owners
    etc/containers/systemd/    quadlets (agentbox, agent-vault, tailscale, net)
    etc/systemd/system/        firewall / vault-init / provision units
    etc/agentbox/firewall.nft  the container egress policy
    etc/tailscale/serve/       tailnet HTTPS routes
build.sh                   build + push both images; build the installer ISO
```

## Build and install

```sh
# build and publish both images (the box pulls these at runtime)
OWNER=youruser ./build.sh agent
OWNER=youruser ./build.sh os
# build the installer ISO (OWNER to pull the pushed OS image; or LOCAL=1)
OWNER=youruser ./build.sh installer      # -> ./output/install.iso
```

### CI (pre-release)

`.github/workflows/build.yml` has two jobs on push to `main` (or manual
dispatch):

- **images** (hosted `ubuntu-latest`) builds and pushes both images to your
  GHCR namespace. It authenticates with the workflow's built-in `GITHUB_TOKEN`
  (`packages: write`) — no PAT, no stored secret.
- **installer** builds `install.iso` and uploads it as an artifact, also on
  `ubuntu-latest`. It uses the `bootc-generic-iso` image type, which takes the
  kernel + EFI tree from an **installer container** (`os/iso`) that we build
  (Anaconda + the Fedora 44 `/usr/lib/efi` → `/boot/efi` copy). Unlike the
  older `bootc-installer` type it does not need a Fedora build host, so it
  builds anywhere with podman + sudo.

While testing it publishes the moving tag `:edge` (the box's quadlets/upgrade
track it); promote a digest to `:latest` and/or flip the packages public at
release.

Nothing machine-specific is baked into the ISO. Boot `output/install.iso`; the
Anaconda text installer asks for everything: pick the target disk, enable
encryption, and set the admin user/password. `%post` then binds the encrypted
root to the TPM, writes the recovery key to `/root/recovery-key.txt`, and you
reboot into the box. Update the OS with `bootc upgrade`; the agent image
auto-updates via `podman-auto-update.timer`.

### Requirements for the build host

- **agent**/**os**/**installer** need only **podman**, plus **`sudo`** for
  `installer` (it builds and mounts into rootful podman storage). Any host
  works; the ISO's EFI/kernel come from the installer container, not the host.
- The `agent`/`os` steps push to `$REGISTRY/$OWNER`; the box pulls the agent
  image from there at runtime, and `bootc upgrade` pulls the OS image.
- `installer` embeds the OS image and records its ref as the installed box's
  update source, so run `./build.sh os` first — it pulls the pushed image by
  default (`REGISTRY_AUTH_FILE`/root's auth must be able to read it). For an
  **offline smoke test**, `LOCAL=1 ./build.sh installer` builds the OS image
  from local storage instead (installs fine, but `bootc upgrade` is left
  pointing at `localhost`).

## First boot

Anaconda creates the admin user with a password (it has no SSH-key field), so
log in with that password first:

```sh
ssh you@agentbox                 # password you set during install
sudo agentbox setup              # SSH key + 3 API keys (+ GHCR pull token if private)
```

`setup` installs your SSH key for the admin user and offers to disable password
logins (key-only). Add more keys later with `sudo agentbox authorize add`.

The disk encryption, TPM binding and recovery key were already done by the
installer (`/root/recovery-key.txt` on the target). `setup` also stores the
Anthropic key, GitHub token and Tailscale auth key in the local vault, then
starts Tailscale and the agent desktop. It prints the desktop / Paseo /
vault-owner passwords **once** — save them.

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
  must be pullable without interactive auth. Public packages need nothing;
  for **private** packages give `agentbox setup` your GHCR username and a
  read-only (`Packages: read`) token — it stores them in the vault and
  `provision` writes `/etc/containers/auth.json` + `/etc/ostree/auth.json` so
  root podman and `bootc upgrade` can pull. Rotate later:
  `sudo agentbox login && sudo agentbox av vault credential set
  GHCR_USER=you GHCR_PULL_TOKEN=... --vault agentbox-boot &&
  sudo systemctl restart agentbox-provision`.

## Known gaps

- **Hostname**: set it at install time (the installer's hostname field, or
  `hostnamectl`); it is deliberately not baked into the image.
- **TPM unlock and firmware updates**: root is bound to PCR 7 (Secure Boot
  state), so a firmware/Secure Boot change can invalidate the TPM keyslot — the
  recovery key written by the installer is the way back in. Keep it safe.
- A Chromium-in-container escape, or misuse within what an API key allows, is
  out of scope.
