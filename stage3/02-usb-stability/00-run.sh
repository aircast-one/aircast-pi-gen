#!/bin/bash -e

install -m 644 files/99-aircast-usb-stability.rules "${ROOTFS_DIR}/etc/udev/rules.d/"
asd
