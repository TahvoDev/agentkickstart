# agentkickstart — build & deploy notes

A memory-jogger for the whole thing. The README is the how-to; this is the
mental model and the gotchas.

## Mental model

- **Build host** = the machine you build on (here: this Ubuntu box).
- **Agent box** = the separate target PC you install onto.
- Three artifacts, produced on the build host:

  | Artifact | Source | Lives / goes |
  | --- | --- | --- |
  | **agent image** (`ghcr.io/OWNER/agentbox-agent`) | `agent/` | a **registry**; the box pulls it at runtime |
  | **OS image** (`ghcr.io/OWNER/agentbox-os`) | `os/` | a **registry**; the box's `bootc upgrade` pulls it |
  | **installer ISO** (`output/install.iso`) | `os/installer.toml` | flashed/booted to lay down the OS |

- The host OS image is tiny (podman + systemd + quadlets). The XFCE desktop and
  both brokers (Agent Vault, Tailscale) run as **containers**.
- Everything the box updates from is a **container ref**. So a registry is the
  hinge: no registry → the box installs but can't update, and the agent
  container can't be pulled.

## Three horizons

### 1) Now, on the build host (one-time)
- Nothing to install: **podman + sudo** are all that's needed. No `os/installer.toml`
  edit — the ISO is generic; the installer asks for everything.
- Optional: decide the **registry namespace** for real deploys (see §3).

### 2) Quick test (smallest end-to-end proof, no registry)
```sh
LOCAL=1 ./build.sh installer     # prompts for sudo; -> output/install.iso
```
- Builds the OS image + installer ISO **offline**. `sudo` is required (rootful
  podman); the `chcon` shim is automatic.
- Proves: OS image builds, ISO builds, Anaconda boots, disk pick + encryption,
  `%post` TPM + recovery, first boot reaches `agentbox setup`.
- Won't show a working **desktop**: the installed box pulls the agent image from
  the registry and `bootc upgrade` points at `localhost` — both fail by design.
- To boot it you need qemu/virt-manager (+ `swtpm` for the TPM); this box has no
  `/dev/kvm`, so it's slow — or install to a spare disk.

### 3) Long term (real deployment)
1. **Registry** with the images:
   ```sh
   OWNER=<namespace> ./build.sh agent     # push agent image
   OWNER=<namespace> ./build.sh os        # push OS image
   OWNER=<namespace> ./build.sh installer # pulls OS ref; bakes it as update source
   ```
   Pushing to GHCR needs a token with **`write:packages`** (the local GitHub App
   token is git/API-only — use a PAT or your own registry).
2. **CI**: on tag, build+push both images; publish `install.iso` as a release.
3. **Runtime updates**: `bootc upgrade` (OS) + `podman-auto-update.timer` (agent).
4. **Private registry** → give the box pull creds (`/etc/ostree/auth.json` + podman auth).
5. **Ops**: back up `/var/lib/agent-vault` + `/etc/agent-vault/master.env`; keep
   the installer's recovery key; TPM PCR-7 changes on firmware/Secure Boot updates.

## Build-host gotchas (this Ubuntu box)
- Rootless podman can't run the builder — it needs to `mount devtmpfs`
  (`mount: /dev: permission denied`). `build.sh` re-runs it under `sudo`.
- Ubuntu has **no SELinux**; the builder `chcon`s its store and fails. `build.sh`
  shims `chcon`/`restorecon`/`fixfiles` out of the builder image.
- Don't build from inside an unprivileged container (devtmpfs needs real root).

## Installer UI: text vs the Cockpit Web UI
- "Cockpit-installer" is **not** a separate image-builder type. It's Anaconda's
  **Web UI** (Cockpit-based, shipped in `anaconda-webui`), which Anaconda uses
  when it's in graphical mode **and** `/usr/share/cockpit/anaconda-webui`
  exists (Fedora 43+). `cockpit-image-builder` is a *build* UI, unrelated.
- image-builder boots the installer with **`inst.text`** (text installer), so
  that's what we get by default.
- `--text`/`--graphical` are argparse `store_const` ⇒ **last on the cmdline
  wins**, and `customizations.kernel.append` appends ⇒ `inst.graphical` selects
  the Web UI. It falls back to text if the Web UI/display isn't available.
- For a headless box you also want `inst.webui.remote` (Cockpit on :9090;
  `inst.webui.remote.pin=NNNN` for a PIN), otherwise there's nothing to view.
- The Web UI has **no SSH-key field either**, so it does not fix the SSH-key
  prompt problem. Kept as a commented opt-in in `os/installer.toml`.

## Installer facts (learned the hard way)
- Image type is **`bootc-installer`** (Anaconda) — `bootc-generic-iso` is
  non-interactive, so no disk picker. Output is always `install.iso`.
- The builder needs **both** `--bootc-ref` **and** `--bootc-installer-payload-ref`
  (both = the OS image) plus `--bootc-pull-container` when pulling from a registry.
- A custom kickstart `contents` is **incompatible** with a
  `[[customizations.user]]` stanza ("kickstart users and/or groups are not
  compatible with user-supplied kickstart content").
- **Anaconda's GUI has no SSH-public-key field** (only "Allow root SSH login with
  password"). So the admin user is created interactively with a password; SSH key
  is added afterwards (`ssh-copy-id`). If you want a key prompt, it has to be a
  first-boot console prompt we write ourselves.
- The installer bakes its payload ref as the box's `bootc upgrade` source — so
  build it against the real registry ref, not `localhost` (that's the `LOCAL=1`
  caveat).

## Repo layout
```
agent/      agent desktop image (Containerfile, opencode.json, nginx.conf, start-agent.sh)
os/         bootc OS image
  Containerfile            dnf install + COPY payload + enable units
  installer.toml           installer blueprint (kickstart: TPM + recovery)
  system/                  host payload, one file per source of truth
build.sh    agent | os | installer
```
