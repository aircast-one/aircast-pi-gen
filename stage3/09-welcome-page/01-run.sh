#!/bin/bash -e

install -D -m 644 files/index.html "${ROOTFS_DIR}/var/www/html/index.html"

on_chroot << EOF
rm -f /var/www/html/index.lighttpd.html
systemctl enable lighttpd.service
EOF
