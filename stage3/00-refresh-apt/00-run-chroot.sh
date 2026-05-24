#!/bin/bash -e

# Refresh apt package lists to ensure we have the latest package versions
# This is critical when using cached stages, as Debian mirrors update packages
# and old versions become unavailable (404 errors)
apt-get update

# Upgrade kernel to include DWC2 USB split-interrupt fix (>= 6.12.35)
# Fixes high-speed USB bug on Pi Zero 2W with flight controllers (Cube Orange)
# See: https://github.com/raspberrypi/linux/pull/6936
apt-get upgrade -y linux-image-rpi-v8 linux-image-rpi-2712 raspi-firmware
