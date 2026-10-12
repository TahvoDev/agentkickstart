#!/usr/bin/env bash
# build.sh - build the agent image, the OS image, and the installer ISO.
#
#   OWNER=<registry-namespace> ./build.sh agent      # build + push the agent image
#   OWNER=<registry-namespace> ./build.sh os         # build + push the OS image
#   ./build.sh installer                             # build ./output/install.iso
#
# agent/os need a registry (the box pulls the agent image at runtime and the OS
# image is what `bootc upgrade` fetches). installer must run on a Fedora host
# with image-builder installed (osbuild needs a Fedora build root to find the
# EFI shim); it pulls the OS ref and writes ./output/install.iso.
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io}
AGENT_TAG=${AGENT_TAG:-latest}
OS_TAG=${OS_TAG:-latest}
LOCAL_OS=${LOCAL_OS:-localhost/agentbox-os:latest}
ROOT_FS=${ROOT_FS:-xfs}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SUDO=(); [ "$(id -u)" -eq 0 ] || SUDO=(sudo)

usage() { echo "usage: OWNER=<ns> $0 agent|os|installer" >&2; exit 2; }

case "${1:-}" in
  agent)
    : "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
    img="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG"
    podman build -f "$HERE/agent/Containerfile" -t "$img" "$HERE"
    podman push "$img"
    ;;

  os)
    : "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
    img="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
    podman build -f "$HERE/os/Containerfile" -t "$img" \
      --build-arg AGENT_IMAGE="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG" "$HERE"
    podman push "$img"
    ;;

  installer)
    # The installer bakes its payload ref as the installed system's update
    # source, so by default it points at the pushed OS image. LOCAL=1 builds
    # offline from local storage instead (installs fine, but `bootc upgrade`
    # is left pointing at localhost and won't work).
    if [ "${LOCAL:-0}" = 1 ]; then
      os_ref="$LOCAL_OS"
      "${SUDO[@]}" podman build -f "$HERE/os/Containerfile" -t "$os_ref" "$HERE"
      pull=()
    else
      : "${OWNER:?set OWNER (or LOCAL=1 for an offline test build)}"
      os_ref="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
      pull=(--bootc-pull-container)
    fi

    # Requires a native image-builder on a Fedora host: osbuild uses the host
    # as its build root there, so the grub2.iso stage finds the EFI shim in
    # /boot/efi. In a container osbuild builds a *separate* root with no Fedora
    # EFI tree, and the build fails on /boot/efi/EFI/fedora/shimx64.efi -- so a
    # hosted Ubuntu runner can't build this ISO.
    command -v image-builder >/dev/null 2>&1 || {
      echo "agentbox: the installer ISO needs a Fedora host:" >&2
      echo "  sudo dnf install image-builder  # then re-run on that host" >&2
      exit 1
    }

    # Registry creds for the OS ref the installer pulls (its own build root).
    auth=${REGISTRY_AUTH_FILE:-/etc/containers/auth.json}
    [ -r "$auth" ] || auth=/etc/containers/auth.json

    mkdir -p "$HERE/output"
    "${SUDO[@]}" env REGISTRY_AUTH_FILE="$auth" \
      image-builder build --output-dir "$HERE/output" bootc-installer \
        --bootc-ref "$os_ref" \
        --bootc-installer-payload-ref "$os_ref" \
        "${pull[@]}" \
        --bootc-default-fs "$ROOT_FS" \
        --blueprint "$HERE/os/installer.toml"
    echo "wrote $HERE/output/install.iso"
    ;;

  *) usage ;;
esac
