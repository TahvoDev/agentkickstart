#!/usr/bin/env bash
# build.sh - substitute the two machine identities into agentbox.bu and compile
# it to agentbox.ign with Butane. Run this on the machine where you install
# Fedora CoreOS.
#
#   ./build.sh --user <admin> --ssh-key '<ssh-ed25519 AAAA...>'
#
# Uses a local butane if installed, otherwise the quay.io/coreos/butane
# container. Refuses to compile if any CHANGEME_* placeholder is left.
set -euo pipefail

USER=; SSH_KEY=
while [ $# -gt 0 ]; do
  case "$1" in
    --user)    USER=${2:?};    shift 2 ;;
    --ssh-key) SSH_KEY=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${USER:?--user required}"
: "${SSH_KEY:?--ssh-key required}"

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

sed -e "s|CHANGEME_USER|$USER|g" \
    -e "s|CHANGEME_SSH_PUBLIC_KEY|$SSH_KEY|g" \
    "$HERE/agentbox.bu" > "$work/agentbox.bu"

if grep -q 'CHANGEME_' "$work/agentbox.bu"; then
  echo "error: unsubstituted CHANGEME_* left in the config" >&2
  exit 1
fi

if command -v butane >/dev/null 2>&1; then
  butane --pretty --strict "$work/agentbox.bu" > "$HERE/agentbox.ign"
else
  podman run --rm -i -v "$work":/files -w /files quay.io/coreos/butane:release \
    --pretty --strict agentbox.bu > "$HERE/agentbox.ign"
fi

echo
echo "wrote $HERE/agentbox.ign"
echo "sha256: $(sha256sum "$HERE/agentbox.ign" | cut -d' ' -f1)"
echo
echo "Install Fedora CoreOS with coreos.inst.ignition_url pointing at that file."
echo "After first boot: ssh $USER@agentbox, then run 'sudo agentbox setup'."
