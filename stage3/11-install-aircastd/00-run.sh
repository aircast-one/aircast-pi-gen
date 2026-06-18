#!/bin/bash -e

# aircastd: device control plane. Serves the landing/status page on port 80 and
# manages the mediamtx and mavp2p systemd units. It replaces the old lighttpd
# welcome page (see removed stage 09-welcome-page).
#
# Two install paths:
#   * Local dev — if files/aircastd (a locally-built arm64 binary, gitignored)
#     is present, bake it straight in with the shipped unit. Lets you test an
#     uncommitted aircastd without publishing a release; see dev-rebuild.sh.
#   * Default — install from the shared, public aircast-apt S3 repository under
#     the "aircastd" prefix (the same repo aircast.one/install.sh uses on real
#     devices), so CI and clean builds need no auth to the private
#     aircast-one/aircastd GitHub repo. The .deb carries the binary AND the unit
#     and enables itself; the channel follows AIRCAST_DISTRIBUTION, so apt pulls
#     the latest aircastd published to that channel.

# Passwordless sudo for the pi user so `just deploy` and remote maintenance can
# install the binary and restart services over SSH without a password prompt.
# Installed before either path so every image gets it.
install -m 440 files/010-aircast-nopasswd "${ROOTFS_DIR}/etc/sudoers.d/010-aircast-nopasswd"

LOCAL_BIN="files/aircastd"
if [ -f "${LOCAL_BIN}" ]; then
	echo "aircastd: baking locally-built binary (${LOCAL_BIN}); skipping S3 apt repo"
	install -m 755 "${LOCAL_BIN}" "${ROOTFS_DIR}/usr/local/bin/aircastd"
	install -m 644 files/aircastd.service "${ROOTFS_DIR}/etc/systemd/system/aircastd.service"
	on_chroot << 'EOF'
systemctl enable aircastd.service
EOF
	exit 0
fi

AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
AIRCAST_APT_KEY_URL="https://aircast-apt.s3.us-east-1.amazonaws.com/public-key.gpg"
AIRCAST_APT_BASE="https://aircast-apt.s3.us-east-1.amazonaws.com/aircastd"

# Signing key (ASCII-armored) -> dearmored rootfs keyring. Host-side curl so we
# get the retry behaviour; gpg is provided by the pi-gen build image.
install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
	"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast.list"

on_chroot << 'EOF'
set -e
# aircastd's postinst runs `systemctl daemon-reload` and `systemctl restart`
# unconditionally, which fail in the build chroot (no running systemd) and would
# abort `apt-get install`. Divert systemctl to a no-op for the install, then
# enable the unit offline afterwards (enable works without a running systemd).
dpkg-divert --local --rename --add /usr/bin/systemctl
ln -sf /bin/true /usr/bin/systemctl

apt-get update
apt-get install -y aircastd

rm -f /usr/bin/systemctl
dpkg-divert --local --rename --remove /usr/bin/systemctl

systemctl enable aircastd.service
EOF
