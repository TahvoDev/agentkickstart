#!/usr/bin/env bash
# perf.sh - time a build phase and log it. A local monitoring harness around
# build.sh; it does not change build behavior. Usage: ./perf.sh agent|os|installer
#
# Appends "<UTC ts> <phase> <seconds>s rc=<n>" to perf.log and routes the podman
# build output to perf-build.log via --logfile, so per-STEP timing is captured.
set -uo pipefail

phase="${1:?usage: $0 agent|os|installer}"
case "$phase" in agent|os|installer) ;; *) echo "unknown phase: $phase" >&2; exit 2; ;; esac

here=$(cd -- "$(dirname -- "$0")" && pwd)
log="$here/perf.log"

# Stream podman build logs to a file too (keeps the console readable).
export PODMAN_BUILD_OPTS="--logfile $here/perf-build.log${PODMAN_BUILD_OPTS:+ $PODMAN_BUILD_OPTS}"

start=$(date +%s)
"$here/build.sh" "$phase"
rc=$?
secs=$(( $(date +%s) - start ))

printf '%s\t%-9s\t%ss\trc=%s\n' "$(date -u +%FT%TZ)" "$phase" "$secs" "$rc" | tee -a "$log"
exit "$rc"
