#!/bin/bash -e
#
# Read-only root + persistent overlay (factory-reset = wipe the writable layer).
# See /Users/.../plans (design) — root is mounted read-only with an overlayfs
# whose upper dir lives on a dedicated "data" partition; factory reset wipes the
# upper dir, reverting the device to the flashed image. Tailscale state is kept
# on data/keep so it survives the reset.
#
# !!! UNTESTED — boot-critical. Build on the Windows box, flash a SPARE SD, and
# work the verification checklist in the plan before flashing any real device.

# First-boot: create the data partition (replaces the rootfs-grow resize).
install -D -m 755 files/aircast-firstboot-data.sh "${ROOTFS_DIR}/usr/local/sbin/aircast-firstboot-data.sh"
install -D -m 644 files/aircast-firstboot-data.service "${ROOTFS_DIR}/etc/systemd/system/aircast-firstboot-data.service"

# Initramfs overlay assembly + factory-reset wipe.
install -D -m 755 files/initramfs-scripts/aircast-overlay "${ROOTFS_DIR}/etc/initramfs-tools/scripts/local-bottom/aircast-overlay"
install -D -m 755 files/initramfs-hooks/aircast-overlay "${ROOTFS_DIR}/etc/initramfs-tools/hooks/aircast-overlay"

# Tailscale survives factory reset (bind from data/keep). The tmpfiles rule
# guarantees keep/tailscale exists on every boot even if first-boot setup was
# interrupted, so the bind mount never silently skips.
install -D -m 644 files/var-lib-tailscale.mount "${ROOTFS_DIR}/etc/systemd/system/var-lib-tailscale.mount"
install -D -m 644 files/aircast-overlay.tmpfiles "${ROOTFS_DIR}/etc/tmpfiles.d/aircast-overlay.conf"

on_chroot << 'EOF'
# We no longer grow rootfs to fill the card; the free space becomes the data
# partition instead.
systemctl disable rpi-resize 2>/dev/null || true

systemctl enable aircast-firstboot-data.service
systemctl enable var-lib-tailscale.mount

# Build the initramfs the firmware auto-loads (config.txt already sets
# auto_initramfs=1). NOT guarded with `|| true`: a failed initramfs build must
# fail the image build, otherwise we'd ship an image that boots WITHOUT the
# overlay (and silently can't factory-reset). NOTE: verify the image lands in
# /boot/firmware on the target — a build-box iteration point.
update-initramfs -c -k all
EOF
