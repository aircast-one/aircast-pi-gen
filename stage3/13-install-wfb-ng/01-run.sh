#!/bin/bash -e

WFB_NG_VERSION="26.8.20.71978-0~trixie"
WFB_NG_KEY_FINGERPRINT="1033488EF8C1C26D3E6DE89B96C08A296DF3F976"

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

gpg --show-keys --with-colons /tmp/wfb-ng.asc \
	| awk -F: '/^fpr/{print \$10; exit}' \
	| grep -qx "${WFB_NG_KEY_FINGERPRINT}"

gpg --dearmor --yes -o /usr/share/keyrings/wfb-ng.gpg /tmp/wfb-ng.asc
rm -f /tmp/wfb-ng.asc

echo "deb [signed-by=/usr/share/keyrings/wfb-ng.gpg] https://apt.wfb-ng.org/ trixie master" \
	> /etc/apt/sources.list.d/wfb-ng.list

apt-get update
apt-get install -y "wfb-ng=${WFB_NG_VERSION}"

apt-mark hold wfb-ng

git clone --filter=blob:none --no-checkout https://github.com/svpcom/rtl8812au.git \
	"/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}"
git -C "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}" \
	fetch --depth 1 origin "${RTL8812AU_COMMIT}"
git -C "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}" \
	checkout --detach "${RTL8812AU_COMMIT}"
rm -rf "/usr/src/${RTL8812AU_MODULE}-${RTL8812AU_MODULE_VERSION}/.git"

dkms add -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}"

built=0
for kbuild in /lib/modules/*/build; do
	kver="\$(basename "\$(dirname "\${kbuild}")")"
	[ -d "\${kbuild}" ] || continue
	echo "wfb-ng: building ${RTL8812AU_MODULE} for \${kver}"
	dkms build -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}" -k "\${kver}"
	dkms install -m "${RTL8812AU_MODULE}" -v "${RTL8812AU_MODULE_VERSION}" -k "\${kver}"
	built=\$((built + 1))
done

kernels=\$(find /lib/modules -mindepth 2 -maxdepth 2 -name modules.order | wc -l)
if [ "\${built}" -lt 1 ] || [ "\${built}" -ne "\${kernels}" ]; then
	echo "wfb-ng: built for \${built} of \${kernels} kernels" >&2
	exit 1
fi

(cd /etc && wfb_keygen)
chmod 600 /etc/drone.key
chmod 644 /etc/gs.key

systemctl disable wifibroadcast@drone.service 2>/dev/null || true
EOF

echo "wfb-ng: installed ${WFB_NG_VERSION} with ${RTL8812AU_MODULE} ${RTL8812AU_MODULE_VERSION}"
