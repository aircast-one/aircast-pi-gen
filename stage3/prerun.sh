#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi

# The cached base rootfs carries the 51cache proxy config from whenever stages
# 0-2 were last baked, so re-sync it with the APT_PROXY of *this* build: pick
# up the proxy on cache-hit builds, and drop a stale proxy that is now down.
if [ -n "$APT_PROXY" ]; then
	install -m 644 "${BASE_DIR}/stage0/00-configure-apt/files/51cache" "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
	sed "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache" -i -e "s|APT_PROXY|${APT_PROXY}|"
else
	rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
fi
