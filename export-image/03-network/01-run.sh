#!/bin/bash -e

rm -f "${ROOTFS_DIR}/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
