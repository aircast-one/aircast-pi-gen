#!/bin/bash -e

# Install Tailscale and enable the daemon.
#
# tailscaled runs on boot but the device is NOT authenticated to any tailnet.
# Joining is an explicit step performed later (manual `tailscale up` or by
# aircast-agent), so no auth key is baked into the image.

on_chroot << EOF
# Add Tailscale repository (Debian bookworm to match the Pi image).
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale

systemctl enable tailscaled.service
EOF
