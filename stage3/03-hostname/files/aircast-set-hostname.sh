#!/bin/bash -e

# Give each device a unique, stable hostname (aircast-<id>) on first boot so the
# recovery hotspot SSID and the Tailscale identity are unique per unit. <id> is
# derived from the Pi CPU serial, falling back to a NIC MAC. One-shot via marker;
# the image still ships the generic "aircast" as the default/fallback.

MARKER=/var/lib/aircast/hostname-set
BASE=aircast

[ -f "$MARKER" ] && exit 0

id="$(awk '/^Serial/ {print $3}' /proc/cpuinfo)"
if [ -z "$id" ]; then
	for ifc in wlan0 eth0; do
		if [ -r "/sys/class/net/$ifc/address" ]; then
			id="$(tr -d ':' < "/sys/class/net/$ifc/address")"
			[ -n "$id" ] && break
		fi
	done
fi

if [ -n "$id" ]; then
	id="${id,,}"
	new="${BASE}-${id: -6}"

	if [ "$(hostname)" != "$new" ]; then
		echo "$new" > /etc/hostname
		hostname "$new"
		if grep -qE '^127\.0\.1\.1' /etc/hosts; then
			sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new}/" /etc/hosts
		else
			printf '127.0.1.1\t%s\n' "$new" >> /etc/hosts
		fi
	fi
fi

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
