#!/bin/bash -e

conf="${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf"
sed -i \
	-e 's/^#\?use-ipv6=.*/use-ipv6=no/' \
	-e 's/^#\?publish-aaaa-on-ipv4=.*/publish-aaaa-on-ipv4=no/' \
	"$conf"
grep -qx 'use-ipv6=no' "$conf"
grep -qx 'publish-aaaa-on-ipv4=no' "$conf"
