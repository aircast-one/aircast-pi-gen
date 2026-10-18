#!/bin/bash -e

install -D -m 755 files/aircast-firstboot-data.sh "${ROOTFS_DIR}/usr/local/sbin/aircast-firstboot-data.sh"
install -D -m 644 files/aircast-firstboot-data.service "${ROOTFS_DIR}/etc/systemd/system/aircast-firstboot-data.service"

install -D -m 755 files/initramfs-scripts/aircast-overlay "${ROOTFS_DIR}/etc/initramfs-tools/scripts/local-bottom/aircast-overlay"
install -D -m 755 files/initramfs-hooks/aircast-overlay "${ROOTFS_DIR}/etc/initramfs-tools/hooks/aircast-overlay"

install -D -m 755 files/initramfs-scripts/aircast-wifi "${ROOTFS_DIR}/etc/initramfs-tools/scripts/init-premount/aircast-wifi"
install -D -m 755 files/initramfs-scripts/aircast-wifi-stop "${ROOTFS_DIR}/etc/initramfs-tools/scripts/local-bottom/aircast-wifi-stop"
install -D -m 755 files/initramfs-hooks/aircast-wifi "${ROOTFS_DIR}/etc/initramfs-tools/hooks/aircast-wifi"

install -D -m 644 files/var-lib-tailscale.mount "${ROOTFS_DIR}/etc/systemd/system/var-lib-tailscale.mount"
install -D -m 644 files/aircast-overlay.tmpfiles "${ROOTFS_DIR}/etc/tmpfiles.d/aircast-overlay.conf"

install -D -m 644 /dev/stdin "${ROOTFS_DIR}/etc/cryptsetup-initramfs/conf-hook" <<'EOF'
CRYPTSETUP=y
EOF

on_chroot << 'EOF'
systemctl disable rpi-resize 2>/dev/null || true

systemctl enable aircast-firstboot-data.service
systemctl enable var-lib-tailscale.mount

update-initramfs -c -k all
EOF
