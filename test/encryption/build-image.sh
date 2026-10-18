#!/bin/bash
set -euo pipefail
export MTOOLS_SKIP_CHECK=1

STAGE=/pi-gen/stage3/12-overlay
HARNESS=/pi-gen/test/encryption
OUT=/out
WORK=/tmp/build
ROOT=$WORK/rootfs
IMG_MB=2048
BOOT_MB=256
BOOT_START=8192

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

if [ -n "${BASE:-}" ] && [ -f "$OUT/$BASE" ]; then
	mkdir -p "$ROOT"
	tar -xpf "$OUT/$BASE" -C "$ROOT"
else
	packages=$(grep -vE '^[[:space:]]*($|#)' "$STAGE/00-packages" | paste -sd, -)
	mmdebstrap --mode=root --variant=apt \
		--include="systemd-sysv,udev,kmod,linux-image-arm64,initramfs-tools,busybox,util-linux,e2fsprogs,procps,iproute2,$packages" \
		trixie "$ROOT" http://deb.debian.org/debian
	if [ -n "${BASE:-}" ]; then
		rm -f "$OUT"/base-*.tar
		tar -cpf "$OUT/$BASE" -C "$ROOT" .
	fi
fi

cp -a "$HARNESS/rootfs/." "$ROOT/"
mkdir -p "$ROOT/boot/firmware"
echo aircast-test >"$ROOT/etc/hostname"
chroot "$ROOT" passwd -d root
sed -i '/^\[defaults\]/a \\tdiscard = false' "$ROOT/etc/mke2fs.conf"
chroot "$ROOT" systemctl enable aircast-test-report.service
rm -f "$ROOT"/boot/initrd.img-*

on_chroot() {
	mount -t proc proc "$ROOT/proc"
	mount -t sysfs sys "$ROOT/sys"
	mount --bind /dev "$ROOT/dev"
	chroot "$ROOT" /bin/bash -e
	local rc=$?
	umount "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"
	return $rc
}
export -f on_chroot
export ROOTFS_DIR="$ROOT" ROOT
(cd /pi-gen/stage0/02-firmware && bash -e ./02-run.sh)
(cd "$STAGE" && bash -e ./00-run.sh)

mkdir -p "$WORK/firmware"
mv "$ROOT"/boot/firmware/* "$WORK/firmware/"
cp "$HARNESS/cmdline.txt" "$WORK/firmware/cmdline.txt"

boot_sectors=$((BOOT_MB * 2048))
root_start=$((BOOT_START + boot_sectors))
root_sectors=$((IMG_MB * 2048 - root_start))

mkfs.vfat -F 32 -n bootfs -C "$WORK/boot.img" $((BOOT_MB * 1024)) >/dev/null
mcopy -i "$WORK/boot.img" "$WORK"/firmware/* ::
truncate -s "$((root_sectors * 512))" "$WORK/root.img"
mkfs.ext4 -q -F -L rootfs -d "$ROOT" "$WORK/root.img"

img="$OUT/disk.img"
rm -f "$img"
truncate -s "${IMG_MB}M" "$img"
sfdisk -q "$img" <<EOF
label: dos
start=$BOOT_START, size=$boot_sectors, type=c
start=$root_start, size=$root_sectors, type=83
EOF
dd if="$WORK/boot.img" of="$img" bs=512 seek="$BOOT_START" conv=notrunc status=none
dd if="$WORK/root.img" of="$img" bs=512 seek="$root_start" conv=notrunc status=none
echo "built $img"
