#!/bin/bash -e

# USB Ethernet gadget: lets a computer cabled to the Pi's USB port reach it at
# 10.55.0.1 (RNDIS for Windows, CDC NCM for macOS/Linux). Requires the dwc2
# controller in OTG mode (see stage1 config.txt) so it stays a USB host for the
# cellular modem when an OTG adapter is used instead.

install -D -m 755 files/aircast-usb-gadget "${ROOTFS_DIR}/usr/local/sbin/aircast-usb-gadget"
install -m 644 files/aircast-usb-gadget.service "${ROOTFS_DIR}/etc/systemd/system/aircast-usb-gadget.service"
install -m 644 files/99-aircast-usb-gadget.rules "${ROOTFS_DIR}/etc/udev/rules.d/99-aircast-usb-gadget.rules"
install -D -m 600 files/usb-gadget.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/usb-gadget.nmconnection"

on_chroot << EOF
systemctl enable aircast-usb-gadget.service
EOF
