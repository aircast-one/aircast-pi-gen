#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -m 644 files/persistent.conf "${ROOTFS_DIR}/etc/systemd/journald.conf.d/persistent.conf"
