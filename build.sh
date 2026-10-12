#!/usr/bin/env bash
# build.sh - build the agent image, the OS image, and the installer ISO.
#
#   OWNER=<registry-namespace> ./build.sh agent      # build + push the agent image
#   OWNER=<registry-namespace> ./build.sh os         # build + push the OS image
#   ./build.sh installer                             # build ./output/install.iso
#
# agent/os need a registry (the box pulls the agent image at runtime and the OS
# image is what `bootc upgrade` fetches). installer is a purely local build: it
# compiles the OS image into rootful podman storage and feeds it to the
# image-builder container, so no registry is required.
#
# Edit os/installer.toml (admin user + SSH key) before building the ISO.
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io}
AGENT_TAG=${AGENT_TAG:-latest}
OS_TAG=${OS_TAG:-latest}
BUILDER_IMAGE=${BUILDER_IMAGE:-ghcr.io/osbuild/image-builder-cli:latest}
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

    # No-op chcon/restorecon shims: the image-builder container relabels its
    # store at startup, which fails on hosts without SELinux (Ubuntu).
    shim=$(mktemp -d); trap 'rm -rf "$shim"' EXIT
    for c in chcon restorecon fixfiles setfiles matchpathcon selabel; do
      printf '#!/bin/sh\nexit 0\n' > "$shim/$c"; chmod +x "$shim/$c"
    done

    # The builder container pulls the OS ref itself, so hand it registry
    # creds: mount an authfile and point REGISTRY_AUTH_FILE at it. Use the
    # caller's ($REGISTRY_AUTH_FILE) if set, else root's. Without this a
    # private OS image fails to pull with "unauthorized".
    auth=${REGISTRY_AUTH_FILE:-/etc/containers/auth.json}
    authmnt=()
    if "${SUDO[@]}" test -r "$auth"; then
      authmnt=(-v "$auth:/etc/containers/auth.json:ro" -e REGISTRY_AUTH_FILE=/etc/containers/auth.json)
    fi

    # osbuild's grub2.iso stage reads the Fedora EFI shim from /boot/efi, so
    # the build host must be Fedora and its EFI tree must be visible in the
    # builder container (no-op on hosts without /boot/efi).
    efimnt=()
    [ -d /boot/efi ] && efimnt=(-v /boot/efi:/boot/efi:ro)

    # Rootful + --privileged is required (it mounts devtmpfs); mount the
    # rootful store so it finds a LOCAL=1 image by ref.
    mkdir -p "$HERE/output"
    "${SUDO[@]}" podman run --rm --privileged \
      "${authmnt[@]}" \
      "${efimnt[@]}" \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      -v "$HERE/output:/output" \
      -v "$HERE/os/installer.toml:/installer.toml:ro" \
      -v "$shim:/shim:ro" \
      -e PATH=/shim:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin \
      "$BUILDER_IMAGE" \
      build --output-dir /output bootc-installer \
        --bootc-ref "$os_ref" \
        --bootc-installer-payload-ref "$os_ref" \
        "${pull[@]}" \
        --bootc-default-fs "$ROOT_FS" \
        --blueprint /installer.toml
    echo "wrote $HERE/output/install.iso"
    ;;

  *) usage ;;
esac
