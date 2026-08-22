#!/bin/bash -e

MEDIAMTX_VERSION="v1.20.1"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64.tar.gz"
MEDIAMTX_SHA256="d1689f0bfefb1864e5ed3dcc8495eb2d7ec0a654f90bf3cd48980cb3bd08718a"

on_chroot << EOF
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o /tmp/mediamtx.tar.gz "${MEDIAMTX_URL}"
echo "${MEDIAMTX_SHA256}  /tmp/mediamtx.tar.gz" | sha256sum -c -
tar -xzf /tmp/mediamtx.tar.gz -C /tmp mediamtx mediamtx.yml
install -m 755 /tmp/mediamtx /usr/local/bin/mediamtx
install -D -m 644 /tmp/mediamtx.yml /usr/local/etc/mediamtx.yml
# Enable the Control API so aircastd applies config changes live (per-path)
# instead of falling back to a full reload. aircastd also enforces this at
# startup; setting it here means fresh images are correct from first boot.
sed -i -E 's/^api: (no|false)$/api: yes/' /usr/local/etc/mediamtx.yml
grep -q '^api: yes$' /usr/local/etc/mediamtx.yml
rm -f /tmp/mediamtx.tar.gz /tmp/mediamtx /tmp/mediamtx.yml
EOF

install -m 644 files/mediamtx.service "${ROOTFS_DIR}/etc/systemd/system/mediamtx.service"

on_chroot << EOF
systemctl enable mediamtx.service
EOF
