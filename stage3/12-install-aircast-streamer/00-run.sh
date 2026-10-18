#!/bin/bash -e

AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
AIRCAST_STREAMER_APT_BASE="https://apt.aircast.one/aircast-streamer"

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_STREAMER_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast-streamer.list"

echo "aircast-streamer: installing from the ${AIRCAST_DISTRIBUTION} channel"

on_chroot << CHROOT
set -e
n=0
until apt-get update; do
	n=\$((n + 1))
	[ "\$n" -lt 5 ] || exit 1
	sleep 30
done
apt-get install -y --no-install-recommends aircast-streamer
dpkg-query -W -f='aircast-streamer: installed \${Version}\n' aircast-streamer
CHROOT
