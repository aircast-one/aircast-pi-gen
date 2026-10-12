#!/bin/bash -e

# aircast-streamer publishes a camera to the SFU over WebRTC. aircastd spawns
# one process per publishing camera and supervises it, so the package carries a
# binary and no unit of its own.
#
# It follows the image's own distribution rather than AIRCAST_APT_CHANNEL: that
# override exists to put an unreleased aircastd on a beta image, and the testing
# channel carries no streamer at all.
AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
AIRCAST_STREAMER_APT_BASE="https://apt.aircast.one/aircast-streamer"

# The keyring comes from 11-install-aircastd, which runs before this.
echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_STREAMER_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast-streamer.list"

echo "aircast-streamer: installing from the ${AIRCAST_DISTRIBUTION} channel"

on_chroot << CHROOT
set -e
apt-get update
apt-get install -y --no-install-recommends aircast-streamer
dpkg-query -W -f='aircast-streamer: installed \${Version}\n' aircast-streamer
CHROOT
