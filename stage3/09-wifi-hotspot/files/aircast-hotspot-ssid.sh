#!/bin/bash -e

# Set the hotspot SSID to the device hostname (set by the flasher via cloud-init).
# NetworkManager keyfiles aren't templated, so rewrite ssid= in place and make a
# running NM pick it up. Runs every boot; no-ops once the keyfile already matches.

PROFILE=/etc/NetworkManager/system-connections/hotspot.nmconnection

[ -f "$PROFILE" ] || exit 0

HOSTNAME="$(hostname)"
[ -n "$HOSTNAME" ] || exit 0

grep -q "^ssid=${HOSTNAME}$" "$PROFILE" && exit 0

sed -i "s/^ssid=.*/ssid=${HOSTNAME}/" "$PROFILE"
# Keyfiles must stay 0600 or NetworkManager refuses to load them.
chmod 600 "$PROFILE"

nmcli connection reload || true
# If the hotspot is the active fallback right now, re-up it so it rebroadcasts
# under the new name. No-op when a client network is connected instead.
if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx hotspot; then
	nmcli connection up hotspot || true
fi
