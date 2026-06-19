#!/bin/bash
# Force SimTech / SIMCOM cellular modems into the QMI USB composition (product
# id 9001) before ModemManager starts.
#
# Why: units of the same SIM7600G-H ship in different USB compositions. Some
# come up in RNDIS/ECM mode (e.g. PID 9011), which exposes only AT serial ports
# and no QMI control port. ModemManager then falls back to legacy PPP dialup,
# which the carrier drops at the IPCP/PDP stage ("Modem hangup" / "No carrier")
# — so the modem registers on the network but never gets a data bearer.
#
# QMI (PID 9001) exposes cdc-wdm0 + wwan0 and connects reliably via the gsm
# NetworkManager profile, the same way the rest of the fleet does. The switch
# is written to the modem's NVRAM (the trailing ",1,1"), so this runs to
# completion only once per modem; on every later boot it fast-paths out.
set -u

VID=1e0e      # Qualcomm / Option SimTech (SIM7600 family)
TARGET=9001   # QMI composition

# Product id of the first attached SimTech modem (empty if none).
modem_pid() {
	lsusb -d "${VID}:" 2>/dev/null | grep -oiE "${VID}:[0-9a-f]+" | head -1 | cut -d: -f2
}

# Send one AT command to a serial port and echo back whatever it replies.
send_at() {
	local dev="$1" cmd="$2" out
	stty -F "$dev" 115200 raw -echo 2>/dev/null || return 1
	exec 9<>"$dev" || return 1
	printf '%s\r' "$cmd" >&9
	out=$(timeout 2 cat <&9)
	exec 9>&-
	printf '%s' "$out"
}

# USB is slow to enumerate at boot; wait briefly for the modem. If none shows
# up there is nothing to do — don't hold up boot.
pid=""
for _ in $(seq 1 8); do
	pid=$(modem_pid)
	[ -n "$pid" ] && break
	sleep 1
done
[ -z "$pid" ] && exit 0
[ "$pid" = "$TARGET" ] && exit 0   # already QMI, nothing to do

logger -t aircast-modem-qmi "modem in USB composition ${pid}; switching to QMI (${TARGET})"

# Find an AT-capable port and request the composition switch. ModemManager is
# ordered after this unit, so the serial ports are free for us to grab.
sent=0
for dev in /dev/ttyUSB*; do
	[ -c "$dev" ] || continue
	send_at "$dev" "AT" | grep -q "OK" || continue
	send_at "$dev" "AT+CUSBPIDSWITCH=${TARGET},1,1" >/dev/null
	sent=1
	break
done
if [ "$sent" != 1 ]; then
	logger -t aircast-modem-qmi "no responsive AT port found; leaving modem as-is"
	exit 0
fi

# The modem reboots and re-enumerates as 9001. Wait for it so ModemManager
# starts against the QMI ports rather than the disappearing RNDIS ones.
for _ in $(seq 1 20); do
	[ "$(modem_pid)" = "$TARGET" ] && { logger -t aircast-modem-qmi "modem now QMI (${TARGET})"; exit 0; }
	sleep 2
done
logger -t aircast-modem-qmi "modem did not return as QMI in time; continuing anyway"
exit 0
