#!/bin/bash -e

# Install Tailscale for persistent SSH access independent of aircast-agent.
# tailscaled runs as its own systemd service and survives agent crashes,
# ensuring remote access is always available.

on_chroot << EOF
# Add Tailscale APT repository (arm64)
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list

# Install tailscale
apt-get update
apt-get install -y tailscale

# Enable tailscaled service (starts on boot, survives agent crashes)
systemctl enable tailscaled.service
EOF
