#!/bin/bash -e

MEDIAMTX_VERSION="v1.21.4"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64.tar.gz"
MEDIAMTX_SHA256="47784081da54c0608ea4dc359f5cfb19880209434769c532b3ed3a67ea99c29d"

on_chroot << EOF
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o /tmp/mediamtx.tar.gz "${MEDIAMTX_URL}"
echo "${MEDIAMTX_SHA256}  /tmp/mediamtx.tar.gz" | sha256sum -c -
tar -xzf /tmp/mediamtx.tar.gz -C /tmp mediamtx mediamtx.yml
install -m 755 /tmp/mediamtx /usr/local/bin/mediamtx
install -D -m 644 /tmp/mediamtx.yml /usr/local/etc/mediamtx.yml
sed -i -E 's/^api: (no|false)$/api: yes/' /usr/local/etc/mediamtx.yml
grep -q '^api: yes$' /usr/local/etc/mediamtx.yml
rm -f /tmp/mediamtx.tar.gz /tmp/mediamtx /tmp/mediamtx.yml
EOF

install -m 644 files/mediamtx.service "${ROOTFS_DIR}/etc/systemd/system/mediamtx.service"

on_chroot << EOF
systemctl enable mediamtx.service
EOF
