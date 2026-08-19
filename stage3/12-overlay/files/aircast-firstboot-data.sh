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
if [ "$created" -eq 0 ] && blkid "$data_part" >/dev/null 2>&1; then
	log "refusing to format $data_part: it already has a filesystem"
	exit 0
fi
log "formatting $data_part ext4 label=$DATA_LABEL"
# -F: non-interactive (a oneshot has no tty), and it overwrites any stale
# filesystem left in the sectors we just claimed.
mkfs.ext4 -F -q -L "$DATA_LABEL" "$data_part"

mnt=$(mktemp -d)
mount "$data_part" "$mnt"
mkdir -p "$mnt/overlay/upper" "$mnt/overlay/work" "$mnt/keep/tailscale"
umount "$mnt"
rmdir "$mnt"

log "data partition ready; rebooting to engage overlay"
systemctl --no-block reboot
