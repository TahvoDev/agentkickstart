#!/usr/bin/env bash
# deploy.sh - fast dev loop against a running bootc agentbox over SSH.
#
#   OWNER=<ns> ./deploy.sh os [ssh-target]      build+push the :dev OS image,
#                                               bootc switch, reboot
#   OWNER=<ns> ./deploy.sh agent [ssh-target]   build+push the agent image, restart it
#   OWNER=<ns> ./deploy.sh gate [ssh-target]    build+push the gate image, restart it
#
# The whole host payload is baked into the OS image, so `os` is the iteration
# loop for anything under os/ (CLI, units, quadlets, firewall). `agent`/`gate`
# only change their container images and just restart the container.
#
# ssh-target defaults to $DEPLOY_TARGET, else "agentbox" (root@ implied).
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
OWNER=${OWNER:-}
REGISTRY=${REGISTRY:-ghcr.io}
OS_TAG=${OS_TAG:-dev}
AGENT_TAG=${AGENT_TAG:-edge}
GATE_TAG=${GATE_TAG:-edge}
TARGET=${DEPLOY_TARGET:-agentbox}

die() { echo "deploy.sh: $*" >&2; exit 1; }
: "${OWNER:?set OWNER to your GHCR namespace}"

cmd=${1:-os}; shift || true
target="${1:-$TARGET}"
case "$target" in *@*) ;; *) target="root@$target" ;; esac

case "$cmd" in
  os)
    ( cd "$HERE" && OS_TAG="$OS_TAG" ./build.sh os )
    ssh "$target" "sudo bootc switch --transport registry $REGISTRY/$OWNER/agentbox-os:$OS_TAG && sudo systemctl reboot"
    echo "switched $target to agentbox-os:$OS_TAG (rebooting)"
    ;;

  agent)
    ( cd "$HERE" && AGENT_TAG="$AGENT_TAG" ./build.sh agent )
    ssh "$target" "sudo podman pull $REGISTRY/$OWNER/agentbox-agent:$AGENT_TAG && sudo systemctl restart agentbox.service"
    echo "updated agent image on $target"
    ;;

  gate)
    ( cd "$HERE" && GATE_TAG="$GATE_TAG" ./build.sh gate )
    ssh "$target" "sudo podman pull $REGISTRY/$OWNER/agentbox-gate:$GATE_TAG && sudo systemctl restart agentbox-gate.service"
    echo "updated gate image on $target"
    ;;

  *)
    die "usage: OWNER=<ns> ./deploy.sh os|agent|gate [ssh-target]"
    ;;
esac
