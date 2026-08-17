#!/bin/bash -e

# aircastd: device control plane. Serves the landing/status page on port 80 and
# manages the mediamtx systemd unit and an in-process MAVLink router. It replaces the old lighttpd
# welcome page (see removed stage 09-welcome-page).
#
# Two install paths:
#   * Local dev — if files/aircastd (a locally-built arm64 binary, gitignored)
#     is present, bake it straight in with the shipped unit. Lets you test an
#     uncommitted aircastd without publishing a release; see build-local.sh.
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

# Default telemetry config: aircastd's in-process MAVLink router listens on the
# standard GCS port so ground stations and the on-device SIYI bridge reach it
# out of the box (this replaces mavp2p's default endpoint). The operator can
# change endpoints/baud in the aircastd UI; a factory reset clears this file.
install -d -m 755 "${ROOTFS_DIR}/var/lib/aircastd"
printf '%s\n' '{"baud":115200,"endpoints":["udps:0.0.0.0:14550"]}' \
	> "${ROOTFS_DIR}/var/lib/aircastd/telemetry.json"
chmod 600 "${ROOTFS_DIR}/var/lib/aircastd/telemetry.json"

# ffmpeg powers the "video file" camera source: an operator uploads a clip in
# the UI, aircastd drops it here and points MediaMTX at it via runOnDemand,
# which runs ffmpeg to loop the file and republish it as RTSP — a stand-in
# camera for testing detection and the overlays. Harmless on camera-only rigs.
install -d -m 755 "${ROOTFS_DIR}/var/lib/aircast/media"
on_chroot << 'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ffmpeg
EOF

LOCAL_BIN="files/aircastd"
if [ -f "${LOCAL_BIN}" ]; then
	echo "aircastd: baking locally-built binary (${LOCAL_BIN}); skipping S3 apt repo"
	# aircast-streamer (the WHIP publisher aircastd spawns by bare name) is
	# installed by its own stage, 11-install-aircast-streamer, which runs first.
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
# get the retry behaviour; gpg is provided by the pi-gen build image. Shared
# with 11-install-aircast-streamer; whichever stage runs first installs it.
install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
if [ ! -f "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg" ]; then
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
		"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"
fi

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast.list"

# Pin to the exact released version so the image is deterministic — a later
# release to the same channel can't change what a rebuild bakes in. Map the
# release tag to its Debian package version: drop the leading 'v' and turn '-'
# into '~' (nfpm's pre-release convention, e.g. v0.0.1-dev.3 -> 0.0.1~dev.3).
# Falls back to channel-latest when no version is provided (local builds).
deb_version() { local v="${1#v}"; echo "${v/-/\~}"; }

if [ -n "${AIRCASTD_VERSION:-}" ]; then
	aircastd_pkg="aircastd=$(deb_version "${AIRCASTD_VERSION}")"
	echo "aircastd: pinning to ${aircastd_pkg}"
else
	aircastd_pkg="aircastd"
	echo "aircastd: no version pin; installing channel-latest"
fi

on_chroot << EOF
set -e
# aircastd's postinst runs \`systemctl daemon-reload\` and \`systemctl restart\`
# unconditionally, which fail in the build chroot (no running systemd) and would
# abort \`apt-get install\`. Divert systemctl to a no-op for the install, then
# enable the unit offline afterwards (enable works without a running systemd).
dpkg-divert --local --rename --add /usr/bin/systemctl
ln -sf /bin/true /usr/bin/systemctl

apt-get update
# Quote the pin: pre-release deb versions contain a tilde (e.g. 0.2.1~dev.2)
# which the shell would otherwise tilde-expand (~ -> /root), corrupting it.
apt-get install -y --allow-downgrades "${aircastd_pkg}"

rm -f /usr/bin/systemctl
dpkg-divert --local --rename --remove /usr/bin/systemctl

systemctl enable aircastd.service
EOF
