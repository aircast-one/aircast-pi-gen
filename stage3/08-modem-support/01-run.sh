#!/bin/bash -e

install -m 644 files/99-aircast-mm-ignore-fc.rules "${ROOTFS_DIR}/etc/udev/rules.d/"
install -D -m 600 files/cellular.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/cellular.nmconnection"

install -d "${ROOTFS_DIR}/etc/systemd/system/ModemManager.service.d"
install -m 644 files/modemmanager-strict.conf "${ROOTFS_DIR}/etc/systemd/system/ModemManager.service.d/filter-policy.conf"

# Switch SimTech modems into the QMI USB composition before ModemManager runs,
# so units that ship in RNDIS/ECM mode still connect via QMI instead of broken
# PPP dialup.
install -m 755 files/aircast-modem-qmi.sh "${ROOTFS_DIR}/usr/local/bin/aircast-modem-qmi.sh"
install -m 644 files/aircast-modem-qmi.service "${ROOTFS_DIR}/etc/systemd/system/aircast-modem-qmi.service"

on_chroot << EOF
systemctl enable ModemManager.service
systemctl enable aircast-modem-qmi.service
EOF
