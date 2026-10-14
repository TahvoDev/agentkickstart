# agentkickstart — build & deploy notes

A memory-jogger for the whole thing. The README is the how-to; this is the
mental model and the gotchas.

## Mental model

- **Build host** = the machine you build on (any host with podman + sudo).
- **Agent box** = the separate target PC you install onto.
- Four artifacts, produced on the build host:

  | Artifact | Source | Lives / goes |
  | --- | --- | --- |
  | **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | a **registry**; the box pulls it at runtime |
  | **gate image** (`ghcr.io/OWNER/agentbox-gate`) | `gate/` | a **registry**; the box pulls it at runtime |
  | **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | a **registry**; the box's `bootc upgrade` pulls it |
  | **installer ISO** (`output/install.iso`) | `os/iso/` | flashed/booted to lay down the OS |

- The host OS image is tiny (podman + systemd + quadlets). The XFCE desktop and
  both brokers (Agent Vault, Tailscale) run as **containers**.
- Everything the box updates from is a **container ref**. So a registry is the
  hinge: no registry → the box installs but can't update, and the agent
  container can't be pulled.

## Three horizons

### 1) Now, on the build host (one-time)
- Nothing to install: **podman + sudo** are all that's needed; the ISO is
  generic and the installer asks for everything.
- Optional: decide the **registry namespace** for real deploys (see §3).

### 2) Quick test (smallest end-to-end proof, no registry)
```sh
LOCAL=1 ./build.sh installer     # prompts for sudo; -> output/install.iso
```
- Builds the OS image + installer ISO **offline**. `sudo` is required (rootful
  podman).
- Proves: OS image builds, ISO builds, Anaconda boots, disk pick + encryption,
  `%post` TPM + recovery, first boot reaches `agentbox setup`.
- Won't show a working **desktop**: the installed box pulls the agent image from
  the registry and `bootc upgrade` points at `localhost` — both fail by design.
- To boot it you need qemu/virt-manager (+ `swtpm` for the TPM); without
  `/dev/kvm` it's slow — or install to a spare disk.

### 3) Long term (real deployment)
1. **Registry** with the images:
   ```sh
   OWNER=<namespace> ./build.sh agent     # push agent image
   OWNER=<namespace> ./build.sh os        # push OS image
   OWNER=<namespace> ./build.sh installer # pulls OS ref; bakes it as update source
   ```
   Pushing to GHCR needs **`packages: write`**. The local GitHub App token can
   log in but **cannot create packages** (`installation not allowed to Create
   organization package`) — so push from **CI**, whose built-in `GITHUB_TOKEN`
   has it (no PAT). See `.github/workflows/build.yml`; it tags `:edge` while
   testing.
2. **CI**: `.github/workflows/build.yml` builds+pushes both images on `main`,
   uploads `install.iso` as an artifact, and keyless-signs both images with
   cosign (then self-verifies the signatures).
3. **Runtime updates**: `bootc upgrade` (OS) + `podman-auto-update.timer` (agent).
4. **Private packages** → `agentbox setup` takes a GHCR username + read-only
   token, stores them in the vault; `provision` writes `/etc/containers/auth.json`
   + `/etc/ostree/auth.json` for root podman and bootc.
5. **Ops**: back up `/var/lib/agent-vault` + `/etc/agent-vault/master.env`; keep
   the installer's recovery key; TPM PCR-7 changes on firmware/Secure Boot updates.

## Build-host gotchas
- Rootless podman can't run the builder — it needs to `mount devtmpfs`
  (`mount: /dev: permission denied`). `build.sh` re-runs it under `sudo`.
- Don't build from inside an unprivileged container (devtmpfs needs real root).

## Installer UI: text vs the Cockpit Web UI
- The ISO menu / kernel options live in `os/iso/iso.yaml`; we boot the **text
  installer** (`inst.text`). Anaconda's Cockpit-based **Web UI** (in
  `anaconda-webui`, Fedora 43+) is selected with `inst.graphical`; for a headless
  box add `inst.webui.remote` (Cockpit on :9090, `inst.webui.remote.pin=NNNN`).
- The Web UI has **no SSH-key field** either, so it does not fix the SSH-key
  prompt problem (see below).

## Installer facts (learned the hard way)
- Use the **`bootc-generic-iso`** image type via `os/iso/` (an installer
  container built from fedora-bootc + Anaconda). The older **`bootc-installer`**
  type needs a *native* Fedora build host: its `grub2.iso` stage reads the EFI
  shim from the build root's `/boot/efi`, which a container build lacks, and
  Fedora 44 moved the shim to `/usr/lib/efi` (osbuild#2525, the `efi_src_dir`
  fix was reverted). `bootc-generic-iso` takes the kernel + EFI tree from the
  installer container instead, so it builds on a hosted `ubuntu-latest` runner.
- The contract: kernel in `/usr/lib/modules/*/vmlinuz` with `initramfs.img`
  beside it, shim/grub in `/boot/efi/EFI/$VENDOR` (copy from `/usr/lib/efi`),
  plus Anaconda and xorriso/squashfs/grub tools. `os/iso/build.sh` does it all.
- The payload is embedded with `--bootc-installer-payload-ref`; Anaconda installs
  it (`containers-storage:<ref>`) and `--target-imgref` sets the box's
  `bootc upgrade` source (`LOCAL=1` leaves it pointing at `localhost`).
- `image-builder` names the ISO itself; `build.sh` renames it to `install.iso`.
- **Erase-and-go disk pick** is a systemd unit (`agentbox-pick.service`,
  `Before=anaconda.service`) that prompts on the console, then rewrites
  `/usr/share/anaconda/interactive-defaults.ks` with the chosen disk. Kickstart
  `%pre` + `%include` can't do this: `%include` is expanded at parse time, before
  `%pre` runs. `autopart --encrypted --passphrase=<random>` keeps Anaconda
  non-interactive; `%post` enrolls the TPM (PCR 7) and writes the recovery key.

## SSH keys: no install-time prompt (by design)
Nothing prompts for an SSH key at install, and that's intentional:
- bootc's SSH-key mechanisms are all **CLI-flag or pre-config**:
  `bootc install --root-ssh-authorized-keys` (flag), **systemd credentials**
  (SMBIOS — qemu/virt only), **cloud-init/Ignition** (metadata), and
  `tmpfiles.d` `authorized_keys` snippets (image content). The docs explicitly
  prefer runtime config: "most configuration should happen at runtime—either at
  first boot or on every boot".
- Anaconda (text, GTK, or Web UI) has **no SSH-key field**; kickstart
  `user --sshkey` is pre-config.

So the ISO stays generic and the key is added after install, by `agentbox`:
`sudo agentbox setup` prompts for the key, installs it for the sudo user
(`~/.ssh/authorized_keys`, dir 0700 / file 0600), and offers to disable password
auth. `sudo agentbox authorize add` adds more keys later. Fedora's default sshd
allows password login, so the very first login uses the installer password.

## Repo layout
```
agent/      agent desktop image (Containerfile, opencode.json, nginx.conf, start-agent.sh)
gate/       gate image (TLS claim UI + vault reverse proxy; --qr for the console)
os/         bootc OS image
  Containerfile            COPY payload + enable units
  iso/                     bootc-generic-iso installer container
    Containerfile
    build.sh               Anaconda + EFI tree + disk picker + kickstart (TPM + recovery)
    iso.yaml               ISO menu / kernel options
  system/                  host payload, one file per source of truth
    usr/bin/               agentbox CLI
    usr/libexec/agentbox/  agentbox-egress (internal helper)
    usr/lib/systemd/       units + logind drop-in
    usr/lib/tmpfiles.d/    volume/config dirs
    usr/lib/bootc/install/ bootc install defaults (root fs)
    usr/share/containers/systemd/  quadlets
    usr/share/agentbox/    static firewall policy, MCP config, tailscale serve config
build.sh    agent | gate | os | installer
deploy.sh   os (build+push :dev, bootc switch) | agent | gate
```

Static image payload lives in `/usr` (immutable, versioned). `/etc` holds only
the durable bootstrap token (`/etc/agentbox/bootstrap.env`). Secrets
(`paseo/proxy/tailscale.env`) are re-fetched into `/run/agentbox/secrets`
(tmpfs) on every boot; live claim state and generated
`firewall.mcp.nft`/`master.env` are runtime-only.

## SELinux

The box runs SELinux enforcing. The one thing that needs care is the tailscale
container opening `/dev/net/tun`: `container_t` has no tun access by default, so
`agentbox-selinux.service` sets the `container_use_devices` boolean at boot.
That relaxes device access for containers that explicitly add one (the device
cgroup still gates it) instead of turning off label separation for the whole
container. Tailscale's state dir is mounted `:Z` and its serve config is staged
into that dir by `agentbox-tailscale-serve.service`, so nothing is mounted from
`/etc` and no host file needs relabeling.

The installer ISO boots its (hand-rolled, not lorax-built) Anaconda environment
with `enforcing=0` (SELinux on, permissive). The installed box enforces SELinux
from the OS image regardless of the installer cmdline.
