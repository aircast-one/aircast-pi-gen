#!/bin/bash
set -euo pipefail

DATA_LABEL=data
MIN_DATA_MB=64

log() { echo "firstboot-data: $*"; logger -t aircast-firstboot-data "$*" 2>/dev/null || true; }

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

if [ "$created" -eq 0 ] && blkid "$data_part" >/dev/null 2>&1 \
	&& [ ! -f /boot/firmware/aircast-encrypt ]; then
	log "refusing to format $data_part: it already has a filesystem"
	exit 0
fi
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

	clevis luks unlock -d "$data_part" -n "$DATA_LABEL" 2>/dev/null \
		|| printf '%s' "$RECOVERY_KEY" | cryptsetup open "$data_part" "$DATA_LABEL" - || {
		log "could not open the encrypted data partition; leaving disk untouched"; exit 0; }
	fs_dev="/dev/mapper/$DATA_LABEL"

	uuid=$(blkid -s UUID -o value "$data_part")
	echo "$DATA_LABEL UUID=$uuid none luks,initramfs" >/etc/crypttab

	CMDLINE=/boot/firmware/cmdline.txt
	if [ -f "$CMDLINE" ] && ! grep -qE '(^| )ip=' "$CMDLINE"; then
		sed -i 's/$/ ip=::::::dhcp/' "$CMDLINE"
	fi

	if [ -n "${WIFI_SSID_HEX:-}" ] && [ -n "${WIFI_PSK:-}" ]; then
		install -d -m 700 /etc/wpa_supplicant
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

	update-initramfs -c -k all

	rm -f "$ENCRYPT_MARKER"
	sync
	log "data partition encrypted (LUKS2 + Tang); recovery marker wiped"
else
	fs_dev="$data_part"
fi

log "formatting $fs_dev ext4 label=$DATA_LABEL"
mkfs.ext4 -F -q -L "$DATA_LABEL" "$fs_dev"

mnt=$(mktemp -d)
mount "$fs_dev" "$mnt"
mkdir -p "$mnt/overlay/upper" "$mnt/overlay/work" "$mnt/keep/tailscale"
umount "$mnt"
rmdir "$mnt"

log "data partition ready; rebooting to engage overlay"
systemctl --no-block reboot
