#!/usr/bin/env bash
# build.sh - build the agent image, the OS image, and the installer ISO.
#
#   OWNER=<registry-namespace> ./build.sh agent      # build + push the agent image
#   OWNER=<registry-namespace> ./build.sh os         # build + push the OS image
#   ./build.sh installer                             # build ./output/install.iso
#
# agent/os need a registry (the box pulls the agent image at runtime and the OS
# image is what `bootc upgrade` fetches). installer builds an installer
# container and turns it into an ISO with the `bootc-generic-iso` image type
# (needs only podman + sudo); it writes ./output/install.iso.
set -euo pipefail

REGISTRY=${REGISTRY:-ghcr.io}
AGENT_TAG=${AGENT_TAG:-latest}
OS_TAG=${OS_TAG:-latest}
BUILDER_IMAGE=${BUILDER_IMAGE:-ghcr.io/osbuild/image-builder-cli:latest@sha256:aba150149bcc26ac3ae56e93628b8383767f0caf4c49dcc98fa2d2045c8b9487}
LOCAL_OS=${LOCAL_OS:-localhost/agentbox-os:latest}
ROOT_FS=${ROOT_FS:-xfs}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SUDO=(); [ "$(id -u)" -eq 0 ] || SUDO=(sudo)

# Optional build tuning, off by default so a plain local build is unchanged:
#   PODMAN_BUILD_OPTS  extra flags for every `podman build` (e.g. --logfile FILE)
#   IB_METRICS=1       ask image-builder for per-stage timing (CI)
read -ra BUILD_OPTS <<<"${PODMAN_BUILD_OPTS:-}"
IB_ARGS=()
[ "${IB_METRICS:-0}" = 1 ] && IB_ARGS+=(--with-metrics)

usage() { echo "usage: OWNER=<ns> $0 agent|os|installer" >&2; exit 2; }

case "${1:-}" in
  agent)
    : "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
    img="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG"
    podman build "${BUILD_OPTS[@]}" -f "$HERE/agent/Containerfile" -t "$img" "$HERE"
    podman push "$img"
    ;;

  os)
    : "${OWNER:?set OWNER to your registry namespace, e.g. OWNER=youruser}"
    img="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
    podman build "${BUILD_OPTS[@]}" -f "$HERE/os/Containerfile" -t "$img" \
      --build-arg AGENT_IMAGE="$REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG" "$HERE"
    podman push "$img"
    ;;

  installer)
    # bootc-generic-iso takes the kernel + EFI tree from an installer container
    # we build here, so it needs only podman (works in a container / any host).
    # The payload is embedded in the ISO's storage and installed by Anaconda.
    if [ "${LOCAL:-0}" = 1 ]; then
      payload_ref="$LOCAL_OS"
      "${SUDO[@]}" podman build "${BUILD_OPTS[@]}" -f "$HERE/os/Containerfile" -t "$payload_ref" "$HERE"
    else
      : "${OWNER:?set OWNER (or LOCAL=1 for an offline test build)}"
      payload_ref="$REGISTRY/$OWNER/agentbox-os:$OS_TAG"
      "${SUDO[@]}" podman pull "$payload_ref"
    fi

    iso_img="localhost/agentbox-iso:latest"
    "${SUDO[@]}" podman build "${BUILD_OPTS[@]}" -f "$HERE/os/iso/Containerfile" -t "$iso_img" \
      --build-arg PAYLOAD_REF="$payload_ref" "$HERE"

    # The builder reads the images from rootful storage; pass registry creds.
    auth=${REGISTRY_AUTH_FILE:-/etc/containers/auth.json}
    authmnt=()
    if "${SUDO[@]}" test -r "$auth"; then
      authmnt=(-v "$auth:/etc/containers/auth.json:ro" -e REGISTRY_AUTH_FILE=/etc/containers/auth.json)
    fi

    mkdir -p "$HERE/output"
    "${SUDO[@]}" podman run --rm --privileged \
      "${authmnt[@]}" \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      -v "$HERE/output:/output" \
      "$BUILDER_IMAGE" \
      build "${IB_ARGS[@]}" --output-dir /output bootc-generic-iso \
        --bootc-ref "$iso_img" \
        --bootc-installer-payload-ref "$payload_ref" \
        --bootc-default-fs "$ROOT_FS"

    # image-builder names the artifact itself; give it our canonical name.
    built=$(ls -1t "$HERE/output/"*.iso 2>/dev/null | head -n1)
    [ -n "$built" ] && mv -f "$built" "$HERE/output/install.iso"
    echo "wrote $HERE/output/install.iso"
    ;;

  *) usage ;;
esac
