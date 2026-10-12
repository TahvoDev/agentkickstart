#!/usr/bin/env bash
# build.sh - build and publish the two bootc artifacts.
#
#   OWNER=<registry-namespace> ./build.sh agent   # build + push the agent image
#   OWNER=<registry-namespace> ./build.sh os      # build + push the OS image
#   OWNER=<registry-namespace> ./build.sh disk    # turn the OS image into a .raw
#
# The agent image is pulled by the box at runtime; the OS image is what
# bootc-image-builder flashes to a disk. Edit os/config.toml (user + SSH key)
# before building a disk.
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io}
: "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
AGENT_TAG=${AGENT_TAG:-latest}
OS_TAG=${OS_TAG:-latest}
DISK_TYPE=${DISK_TYPE:-raw}

AGENT_IMAGE="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG"
OS_IMAGE="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
HERE=$(cd -- "$(dirname -- "$0")" && pwd)

build() { podman build -f "$1" -t "$2" "$HERE"; }

case "${1:-}" in
  agent)
    build "$HERE/agent/Containerfile" "$AGENT_IMAGE"
    podman push "$AGENT_IMAGE"
    ;;
  os)
    build "$HERE/os/Containerfile" "$OS_IMAGE"
    podman push "$OS_IMAGE"
    ;;
  disk)
    mkdir -p "$HERE/output"
    podman run --rm --privileged --security-opt label=type:unconfined_t \
      -v "$HERE/output:/output" \
      -v "$HERE/os/config.toml:/config.toml:ro" \
      quay.io/centos-bootc/bootc-image-builder:latest \
      --type "$DISK_TYPE" --config /config.toml "$OS_IMAGE"
    echo "wrote $HERE/output/image/disk.$DISK_TYPE"
    ;;
  *)
    echo "usage: OWNER=<ns> $0 agent|os|disk" >&2
    exit 2
    ;;
esac
