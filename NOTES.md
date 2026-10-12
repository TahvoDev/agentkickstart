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
   Pushing to GHCR needs **`packages: write`**. The local GitHub App token can
   log in but **cannot create packages** (`installation not allowed to Create
   organization package`) — so push from **CI**, whose built-in `GITHUB_TOKEN`
   has it (no PAT). See `.github/workflows/build.yml`; it tags `:edge` while
   testing.
2. **CI**: `.github/workflows/build.yml` builds+pushes both images on `main`,
   uploads `install.iso` as an artifact.
3. **Runtime updates**: `bootc upgrade` (OS) + `podman-auto-update.timer` (agent).
4. **Private packages** → `agentbox setup` takes a GHCR username + read-only
   token, stores them in the vault; `provision` writes `/etc/containers/auth.json`
   + `/etc/ostree/auth.json` for root podman and bootc.
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
- The installer bakes its payload ref as the box's `bootc upgrade` source — so
  build it against the real registry ref, not `localhost` (that's the `LOCAL=1`
  caveat).

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
os/         bootc OS image
  Containerfile            dnf install + COPY payload + enable units
  installer.toml           installer blueprint (kickstart: TPM + recovery)
  system/                  host payload, one file per source of truth
build.sh    agent | os | installer
```
