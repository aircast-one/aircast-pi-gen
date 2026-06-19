#!/bin/bash -e

install -m 644 files/99-tailscale.conf "${ROOTFS_DIR}/etc/sysctl.d/99-tailscale.conf"

on_chroot << EOF
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale

systemctl enable tailscaled.service
EOF
