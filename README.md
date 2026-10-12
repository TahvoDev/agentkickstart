# agentkickstart

A single Fedora CoreOS Butane config that boots a self-contained agent box:

- **Paseo + OpenCode agents** running on a real XFCE desktop (Xvfb + x11vnc +
  noVNC), reached from any tailnet device at `https://agentbox.<tailnet>.ts.net:8443`.
- **Local Agent Vault** (its own unprivileged container) that brokers the
  Anthropic/GitHub credentials; the agent only ever holds dummy keys and a
  proxy-role token that cannot read the real values.
- **TPM-backed LUKS root** so a pulled drive is unreadable.
- **nftables egress policy** so container traffic can reach the internet but not
  your LAN, the tailnet, link-local, or the host itself (DNS excepted).

No secrets live in the ignition. On first boot `agentbox setup` asks for the
three API keys, stores them in the local vault, and starts everything.

## Layout

```
agentbox.bu   the Butane config (the whole box)
build.sh      substitute your user + SSH key, then compile to agentbox.ign
```

## Quick start

```sh
# 1. Build the ignition (edit nothing in agentbox.bu).
./build.sh --user yourname --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"

# 2. Install Fedora CoreOS pointing coreos.inst.ignition_url at agentbox.ign.

# 3. First boot, over the LAN:
ssh yourname@agentbox
sudo agentbox setup                  # asks for the 3 keys, does the rest
sudo systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/root
```

Save the desktop / Paseo / vault-owner passwords the setup prints — they are
shown once.

## Daily use

```sh
sudo agentbox up|status|logs|shell     # sync secrets, restart, inspect
sudo agentbox login|logout|av <args>   # vault owner session / CLI
sudo agentbox allow <ip|cidr>...       # let an MCP reach a LAN/tailnet host
sudo agentbox allow clear              # revoke all of them
```

### Reaching a LAN/tailnet service from an MCP

By default the container can only reach the internet, so an MCP that talks to a
local service (Home Assistant, a LAN model server, a NAS, another tailnet host)
is blocked. Opt specific destinations in without opening the whole range:

```sh
sudo agentbox allow 192.168.1.20              # Home Assistant
sudo agentbox allow 192.168.1.0/24 100.90.0.7 # a subnet + one tailnet host
sudo agentbox allow                           # show the current allowlist
```

This edits `/etc/agentbox/firewall.allow.nft` and reloads the policy; it
survives reboots. It is IPv4/IPv6 per-destination, not per-port.

Two things the allowlist deliberately does **not** do:

- It does not expose the **host itself**. A service bound on the host stays
  unreachable; run it as a container on the `agentbox` network instead.
- It does not make mDNS `.local` names resolvable — use an IP or a name your
  DNS server knows.

Every destination you add is another place a compromised agent could pivot to,
so keep the list as small as the MCP actually needs.

URLs, both tailnet-only:

| URL | What |
| --- | --- |
| `https://agentbox.<tailnet>.ts.net` | Paseo |
| `https://agentbox.<tailnet>.ts.net:8443` | desktop (login user `agent`) |

## Back up

`/var/lib/agent-vault` and `/etc/agent-vault/master.env`.

## Before you build

- The Tailscale auth key must be **tagged `tag:agentbox`** and that tag must be
  allowed to mint HTTPS certs in your tailnet ACLs.
- The GitHub token should be **fine-grained and repo-scoped**; the Anthropic key
  should have a **spend limit**. The box brokers these keys, so a key's blast
  radius is whatever the key itself allows.
- Not covered: a Chromium-in-container escape, or misuse within what an API key
  permits.
