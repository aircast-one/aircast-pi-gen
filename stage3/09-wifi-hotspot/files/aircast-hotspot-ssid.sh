#!/bin/bash -e

PROFILE=/etc/NetworkManager/system-connections/hotspot.nmconnection

[ -f "$PROFILE" ] || exit 0

host="$(hostname)"
[ -n "$host" ] || exit 0

ssid="${host:0:32}"

grep -q "^ssid=${ssid}$" "$PROFILE" && exit 0

sed -i "s/^ssid=.*/ssid=${ssid}/" "$PROFILE"
chmod 600 "$PROFILE"

nmcli connection reload || true
if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx hotspot; then
	nmcli connection up hotspot || true
fi
