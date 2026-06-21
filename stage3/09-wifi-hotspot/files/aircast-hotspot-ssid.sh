#!/bin/bash -e

# Set the hotspot SSID to the device hostname. NetworkManager keyfiles are not
# templated, so rewrite ssid= in place before NM activates the AP profile. Runs
# every boot (cheap, idempotent) so the SSID tracks hostname changes on reboot.

PROFILE=/etc/NetworkManager/system-connections/hotspot.nmconnection

[ -f "$PROFILE" ] || exit 0

HOSTNAME="$(hostname)"
[ -n "$HOSTNAME" ] || exit 0

if ! grep -q "^ssid=${HOSTNAME}$" "$PROFILE"; then
	sed -i "s/^ssid=.*/ssid=${HOSTNAME}/" "$PROFILE"
	# Keyfiles must stay 0600 or NetworkManager refuses to load them.
	chmod 600 "$PROFILE"
fi
