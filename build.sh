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
    podman build -f "$HERE/os/Containerfile" -t "$img" "$HERE"
    podman push "$img"
    ;;

  installer)
    # 1. Build the OS image into *rootful* storage (the builder uses local
    #    container storage, so no registry or network pull is needed).
    "${SUDO[@]}" podman build -f "$HERE/os/Containerfile" -t "$LOCAL_OS" "$HERE"

    # 2. No-op chcon/restorecon shims: the image-builder container relabels its
    #    store at startup, which fails on hosts without SELinux (Ubuntu).
    shim=$(mktemp -d); trap 'rm -rf "$shim"' EXIT
    for c in chcon restorecon fixfiles setfiles matchpathcon selabel; do
      printf '#!/bin/sh\nexit 0\n' > "$shim/$c"; chmod +x "$shim/$c"
    done

    # 3. Build the ISO. Rootful + --privileged is required (it mounts devtmpfs);
    #    mount the rootful store so it finds the OS image by ref.
    mkdir -p "$HERE/output"
    "${SUDO[@]}" podman run --rm --privileged \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      -v "$HERE/output:/output" \
      -v "$HERE/os/installer.toml:/installer.toml:ro" \
      -v "$shim:/shim:ro" \
      -e PATH=/shim:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin \
      "$BUILDER_IMAGE" \
      build --output-dir /output bootc-installer \
        --bootc-ref "$LOCAL_OS" \
        --bootc-installer-payload-ref "$LOCAL_OS" \
        --bootc-default-fs "$ROOT_FS" \
        --blueprint /installer.toml
    echo "wrote $HERE/output/install.iso"
    ;;

  *) usage ;;
esac
