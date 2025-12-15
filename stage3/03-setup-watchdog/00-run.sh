#!/bin/bash -e

# Configure watchdog for auto-reboot on system hang
on_chroot << EOF
# Configure watchdog.conf
sed -i 's|^#watchdog-device.*|watchdog-device = /dev/watchdog|' /etc/watchdog.conf
sed -i 's|^#max-load-1.*|max-load-1 = 24|' /etc/watchdog.conf
sed -i 's|^#watchdog-timeout.*|watchdog-timeout = 15|' /etc/watchdog.conf

# Enable watchdog service
systemctl enable watchdog
EOF
