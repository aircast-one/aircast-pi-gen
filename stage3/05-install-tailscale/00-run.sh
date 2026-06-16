#!/bin/bash -e

# Standalone tailscaled for out-of-band SSH that survives agent crashes,
# separate from the agent's embedded tsnet sidecar.
on_chroot << EOF
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale

systemctl enable tailscaled.service
EOF
