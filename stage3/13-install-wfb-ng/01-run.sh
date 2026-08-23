#!/bin/bash -e

# wfb-ng gives a device its own radio link: video and telemetry keep flowing
# where there is no cellular coverage and through jamming. aircastd sends RTP
# to the drone profile's video port; wfb_tx puts it on the air.
#
# Two halves have to be installed together. The wfb-ng userspace comes from
# upstream's apt repo. The driver does not exist as a package for this kernel,
# so it is built here with DKMS — once per kernel flavour the image ships,
# because Pi 3/4 and Pi 5 run different ones and the module has to match.

WFB_NG_VERSION="26.8.20.71978-0~trixie"
WFB_NG_KEY_FINGERPRINT="1033488EF8C1C26D3E6DE89B96C08A296DF3F976"

# svpcom's wfb fork of the 8812au driver. Pinned to a commit, not a branch:
# the tree has no releases, and an unpinned clone would silently change what
# every image carries. This one fixes the build against Pi kernel 6.18 headers.
RTL8812AU_COMMIT="6e75916416de1dce5ecd37f824896bebf96aaf8f"
RTL8812AU_MODULE="realtek-rtl88xxau"
RTL8812AU_MODULE_VERSION="5.2.20.2~20190429"

install -m 644 files/wfb.conf "${ROOTFS_DIR}/etc/modprobe.d/wfb.conf"
install -m 644 files/wifibroadcast.cfg "${ROOTFS_DIR}/etc/wifibroadcast.cfg"
install -m 644 files/99-wfb-ng.rules "${ROOTFS_DIR}/etc/udev/rules.d/99-wfb-ng.rules"

on_chroot << EOF
set -e

curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
	https://apt.wfb-ng.org/public.asc -o /tmp/wfb-ng.asc

# The repo is pinned by key, and the key by fingerprint. Fetching a signing
# key over TLS and trusting whatever comes back would leave the pin decorative.
gpg --show-keys --with-colons /tmp/wfb-ng.asc \
	| awk -F: '/^fpr/{print \$10; exit}' \
	| grep -qx "${WFB_NG_KEY_FINGERPRINT}"

gpg --dearmor --yes -o /usr/share/keyrings/wfb-ng.gpg /tmp/wfb-ng.asc
rm -f /tmp/wfb-ng.asc

echo "deb [signed-by=/usr/share/keyrings/wfb-ng.gpg] https://apt.wfb-ng.org/ trixie master" \
	> /etc/apt/sources.list.d/wfb-ng.list

apt-get update
apt-get install -y "wfb-ng=${WFB_NG_VERSION}"

# Nothing here should follow the repo forward on an apt upgrade: the driver is
# built against one userspace and the pair is what was tested.
apt-mark hold wfb-ng

git clone --filter=blob:none --no-checkout https://github.com/svpcom/rtl8812au.git \
	"/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}"
git -C "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}" \
	fetch --depth 1 origin "${RTL8812AU_COMMIT}"
git -C "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}" \
	checkout --detach "${RTL8812AU_COMMIT}"
rm -rf "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}/.git"

dkms add -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}"

# Both kernel flavours the image ships, so one card works on a Pi 4 and a Pi 5.
# A flavour whose headers are missing is a build error, not something to skip:
# skipping it produces an image that boots fine and has no radio.
built=0
for kbuild in /lib/modules/*/build; do
	kver="\$(basename "\$(dirname "\${kbuild}")")"
	[ -d "\${kbuild}" ] || continue
	echo "wfb-ng: building ${RTL8812AU_MODULE} for \${kver}"
	dkms build -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}" -k "\${kver}"
	dkms install -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}" -k "\${kver}"
	built=\$((built + 1))
done

if [ "\${built}" -lt 2 ]; then
	echo "wfb-ng: expected both kernel flavours, built \${built}" >&2
	exit 1
fi

# One keypair per image, not per device: the fleet flies to one ground station,
# and a key generated per device would mean a separate gs.key for every drone.
# /etc/gs.key is the half that has to reach the ground station.
(cd /etc && wfb_keygen)
chmod 600 /etc/drone.key
chmod 644 /etc/gs.key

# The unit is deliberately not enabled — the udev rule starts it when a
# supported adapter is actually present.
systemctl disable wifibroadcast@drone.service 2>/dev/null || true
EOF

echo "wfb-ng: installed ${WFB_NG_VERSION} with ${RTL8812AU_MODULE} ${RTL8812AU_MODULE_VERSION}"
