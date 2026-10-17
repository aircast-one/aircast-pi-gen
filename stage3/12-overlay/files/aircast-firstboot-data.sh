#!/bin/bash
# aircast-firstboot-data: one-shot, runs on the FIRST boot only (before the
# overlay engages). The image ships with just boot+rootfs; this carves a third
# "data" partition out of the remaining card space and lays out the writable
# layer the overlay needs:
#
#   data/overlay/{upper,work}  -> the writable layer (wiped on factory reset)
#   data/keep/tailscale        -> bind-mounted to /var/lib/tailscale (survives reset)
#
# After the partition exists, the next boot's initramfs hook (aircast-overlay)
# mounts root read-only with an overlay on top.
#
# Resumable and fail-safe: every abort path leaves the disk in a state the next
# boot can finish, and never reboots into a broken layout. A missing/!= label
# data partition is (re)used in place; we never create a duplicate.
#
# !!! Boot path validated only by build; the runtime path needs a spare-SD
# flash + boot test (see plan verification). A bug here can brick the card.
set -euo pipefail

DATA_LABEL=data
MIN_DATA_MB=64

log() { echo "firstboot-data: $*"; logger -t aircast-firstboot-data "$*" 2>/dev/null || true; }

# Fully done already.
if blkid -L "$DATA_LABEL" >/dev/null 2>&1; then
	exit 0
fi

root_part=$(findmnt -no SOURCE /)
case "$root_part" in
	/dev/mmcblk*p[0-9]) disk=${root_part%p[0-9]}; partprefix="${disk}p" ;;
	/dev/nvme*p[0-9])   disk=${root_part%p[0-9]}; partprefix="${disk}p" ;;
	/dev/sd[a-z][0-9])  disk=${root_part%[0-9]};  partprefix="$disk" ;;
	*) log "unsupported root device '$root_part'; leaving disk untouched"; exit 0 ;;
esac
data_part="${partprefix}3"

# Create partition 3 only if it does not already exist (resume a partial run
# without ever making a duplicate).
created=0
if [ ! -b "$data_part" ]; then
	table=$(parted -ms "$disk" unit s print)
	end_p2=$(printf '%s\n' "$table" | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')
	disk_end=$(printf '%s\n' "$table" | awk -F: -v d="$disk" '$1==d{gsub(/s/,"",$2); print $2}')
	case "${end_p2}-${disk_end}" in
		*[!0-9-]*|-*|*-) log "could not parse partition table; leaving disk untouched"; exit 0 ;;
	esac
	start=$((end_p2 + 1))
	end=$((disk_end - 1))
	free_mb=$(((end - start) * 512 / 1024 / 1024))
	if [ "$end" -le "$start" ] || [ "$free_mb" -lt "$MIN_DATA_MB" ]; then
		log "insufficient free space for data partition (${free_mb}MB); leaving disk untouched"
		exit 0
	fi
	log "creating data partition: sectors ${start}..${end} (~${free_mb}MB)"
	# Explicit "s" suffix on each value — unambiguous across parted versions.
	parted -s -a optimal "$disk" mkpart primary ext4 "${start}s" "${end}s"
	created=1
fi

partprobe "$disk" 2>/dev/null || true
udevadm settle 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -b "$data_part" ] && break
	sleep 1; partprobe "$disk" 2>/dev/null || true; udevadm settle 2>/dev/null || true
done
if [ ! -b "$data_part" ]; then
	log "partition 3 ($data_part) did not appear; leaving disk untouched"
	exit 0
fi

# Refuse to clobber a partition that was already on the disk when we got here.
# A partition we just carved out ourselves is different: the image's own table
# never claimed those sectors, so any filesystem sitting there is a leftover from
# the card's previous life and formatting it is the whole point. Without this
# distinction a re-flashed card dead-ends here — the old data partition is found,
# never labelled, and the overlay silently never engages.
#
# The encrypt marker is an explicit instruction to (re)encrypt this card, so it
# overrides the guard: a half-enrolled LUKS partition from an interrupted run
# (e.g. update-initramfs failed before the marker was wiped) must be reformatted
# and re-enrolled on the next boot, not refused.
if [ "$created" -eq 0 ] && blkid "$data_part" >/dev/null 2>&1 \
	&& [ ! -f /boot/firmware/aircast-encrypt ]; then
	log "refusing to format $data_part: it already has a filesystem"
	exit 0
fi
# When the flasher left an aircast-encrypt marker on the boot partition, the
# data partition becomes a LUKS2 container unlocked at every boot by Clevis
# against one or more Tang servers (network-bound disk encryption). The marker
# is sourced for CLEVIS_CFG (an sss policy JSON with each Tang advertisement
# inlined, so enrolment needs no network) and RECOVERY_KEY. Slot 0 is the
# operator's recovery passphrase (break-glass); slot 1 is the Clevis binding.
# The marker holds the recovery key in clear, so it is wiped off the card the
# moment enrolment succeeds — after that only the flasher/operator holds it.
ENCRYPT_MARKER=/boot/firmware/aircast-encrypt
if [ -f "$ENCRYPT_MARKER" ]; then
	# shellcheck disable=SC1090
	. "$ENCRYPT_MARKER"
	if [ -z "${CLEVIS_CFG:-}" ] || [ -z "${RECOVERY_KEY:-}" ]; then
		log "encrypt marker present but incomplete (need CLEVIS_CFG, RECOVERY_KEY); leaving disk untouched"
		exit 0
	fi

	log "LUKS-formatting $data_part (recovery slot)"
	printf '%s' "$RECOVERY_KEY" | cryptsetup luksFormat --type luks2 --batch-mode "$data_part" - || {
		log "luksFormat failed; leaving disk untouched"; exit 0; }

	log "binding Clevis sss policy to $data_part"
	printf '%s' "$RECOVERY_KEY" | clevis luks bind -d "$data_part" -k - -y sss "$CLEVIS_CFG" || {
		log "clevis bind failed; leaving disk untouched"; exit 0; }

	# Open now (first boot, Tang is reachable). Fall back to the recovery key so
	# a transient Tang hiccup here doesn't dead-end first-boot setup.
	clevis luks unlock -d "$data_part" -n "$DATA_LABEL" 2>/dev/null \
		|| printf '%s' "$RECOVERY_KEY" | cryptsetup open "$data_part" "$DATA_LABEL" - || {
		log "could not open the encrypted data partition; leaving disk untouched"; exit 0; }
	fs_dev="/dev/mapper/$DATA_LABEL"

	# crypttab drives the stock clevis-initramfs unlock on every later boot;
	# _netdev brings networking up in the initramfs so Tang is reachable.
	uuid=$(blkid -s UUID -o value "$data_part")
	echo "$DATA_LABEL UUID=$uuid none luks,_netdev" >/etc/crypttab

	# The initramfs must bring networking up to reach Tang, which needs ip= on
	# the kernel cmdline — Raspberry Pi OS ships none. Add it only here, so an
	# unencrypted card never pays the DHCP wait. cmdline.txt is a single line.
	CMDLINE=/boot/firmware/cmdline.txt
	if [ -f "$CMDLINE" ] && ! grep -qw 'ip=dhcp' "$CMDLINE"; then
		sed -i 's/$/ ip=dhcp/' "$CMDLINE"
	fi

	# Wifi uplink: the initramfs must associate wlan0 before it can reach Tang,
	# so stage a supplicant config the aircast-wifi hook pulls into the initramfs.
	# The PSK lives in the (unencrypted) initramfs by necessity — it is needed
	# before the card is decrypted — so only the data partition is protected, not
	# the wifi credential.
	if [ -n "${WIFI_SSID_HEX:-}" ] && [ -n "${WIFI_PSK:-}" ]; then
		install -d -m 700 /etc/wpa_supplicant
		# ssid as bare hex (no quotes) so a special character in the SSID can't
		# break the config; psk is the derived 64-hex key, also unquoted.
		( umask 077; cat >/etc/wpa_supplicant/aircast-initramfs.conf <<WPAEOF
country=${WIFI_COUNTRY:-US}
ctrl_interface=/run/wpa_supplicant
network={
	ssid=$WIFI_SSID_HEX
	psk=$WIFI_PSK
}
WPAEOF
		)
		log "wifi creds staged for initramfs unlock (wlan0)"
	fi

	# Rebuild the initramfs the firmware auto-loads so it carries this crypttab
	# entry, the LUKS device's keys and the clevis/network tooling. Without this
	# the next boot has no way to unlock the card.
	update-initramfs -u

	# The recovery key lived on the card only to seed this one enrolment. Now
	# the LUKS header holds the binding; drop the clear copy.
	rm -f "$ENCRYPT_MARKER"
	sync
	log "data partition encrypted (LUKS2 + Tang); recovery marker wiped"
else
	fs_dev="$data_part"
fi

log "formatting $fs_dev ext4 label=$DATA_LABEL"
# -F: non-interactive (a oneshot has no tty), and it overwrites any stale
# filesystem left in the sectors we just claimed.
mkfs.ext4 -F -q -L "$DATA_LABEL" "$fs_dev"

mnt=$(mktemp -d)
mount "$fs_dev" "$mnt"
mkdir -p "$mnt/overlay/upper" "$mnt/overlay/work" "$mnt/keep/tailscale"
umount "$mnt"
rmdir "$mnt"

log "data partition ready; rebooting to engage overlay"
systemctl --no-block reboot
