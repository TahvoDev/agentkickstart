#!/bin/bash
set -eu
: "${PASSWORD:?desktop PASSWORD missing}"
export DISPLAY=:1 HOME=/home/agent
export XDG_RUNTIME_DIR=/tmp/runtime-agent
mkdir -p -m 700 "$XDG_RUNTIME_DIR" /tmp/nx

# One D-Bus session for the desktop, MCP servers and agents.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  exec dbus-run-session -- "$0" "$@"
fi

Xvfb "$DISPLAY" -screen 0 "${RESOLUTION:-1600x900x24}" -nolisten tcp &
until xdpyinfo >/dev/null 2>&1; do sleep 0.5; done
startxfce4 >/dev/null 2>&1 &

# VNC and websockify listen on loopback only; nginx adds the login.
x11vnc -display "$DISPLAY" -localhost -nopw -forever -shared -rfbport 5900 -quiet >/dev/null 2>&1 &
websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >/dev/null 2>&1 &
printf 'agent:%s\n' "$(openssl passwd -apr1 "$PASSWORD")" > /tmp/htpasswd
nginx -e /dev/stderr -c /etc/nginx-agentbox.conf &

cd /workspace
git rev-parse >/dev/null 2>&1 || git init -q
exec agent-vault run -- paseo daemon run
