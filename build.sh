#!/usr/bin/env bash
# build.sh - build and publish the agent image and the OS image, then the
# interactive installer ISO.
#
#   OWNER=<registry-namespace> ./build.sh agent      # build + push the agent image
#   OWNER=<registry-namespace> ./build.sh os         # build + push the OS image
#   OWNER=<registry-namespace> ./build.sh installer  # build output/install.iso
#
# The agent image is pulled by the box at runtime; the OS image is what the
# installer lays down. Edit os/installer.toml (admin user + SSH key) first.
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io}
: "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
AGENT_TAG=${AGENT_TAG:-latest}
OS_TAG=${OS_TAG:-latest}

AGENT_IMAGE="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG"
OS_IMAGE="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
BUILDER_IMAGE=${BUILDER_IMAGE:-ghcr.io/osbuild/image-builder-cli:latest}
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
  installer)
    mkdir -p "$HERE/output"
    podman run --rm --privileged --security-opt label=type:unconfined_t \
      -v "$HERE/output:/output" \
      -v "$HERE/os/installer.toml:/installer.toml:ro" \
      "$BUILDER_IMAGE" \
      build --output-dir /output bootc-installer \
        --bootc-ref "$OS_IMAGE" \
        --bootc-installer-payload-ref "$OS_IMAGE" \
        --bootc-pull-container \
        --bootc-default-fs "${ROOT_FS:-xfs}" \
        --blueprint /installer.toml
    echo "wrote $HERE/output/install.iso"
    ;;
  *)
    echo "usage: OWNER=<ns> $0 agent|os|installer" >&2
    exit 2
    ;;
esac
