#!/bin/bash -e

MAVP2P_VERSION="v1.3.3"
MAVP2P_URL="https://github.com/bluenviron/mavp2p/releases/download/${MAVP2P_VERSION}/mavp2p_${MAVP2P_VERSION}_linux_arm64v8.tar.gz"
MAVP2P_SHA256="174bbd85e6353e6f8fd006adc64629ea40e2f8897d308cd75043ec9a72ba8c6f"

on_chroot << EOF
curl -fsSL -o /tmp/mavp2p.tar.gz "${MAVP2P_URL}"
echo "${MAVP2P_SHA256}  /tmp/mavp2p.tar.gz" | sha256sum -c -
tar -xzf /tmp/mavp2p.tar.gz -C /tmp mavp2p
install -m 755 /tmp/mavp2p /usr/local/bin/mavp2p
rm -f /tmp/mavp2p.tar.gz /tmp/mavp2p
EOF

install -m 755 files/mavp2p-autostart "${ROOTFS_DIR}/usr/local/bin/mavp2p-autostart"
install -m 644 files/mavp2p.default "${ROOTFS_DIR}/etc/default/mavp2p"
install -m 644 files/mavp2p.service "${ROOTFS_DIR}/etc/systemd/system/mavp2p.service"

on_chroot << EOF
systemctl enable mavp2p.service
EOF
