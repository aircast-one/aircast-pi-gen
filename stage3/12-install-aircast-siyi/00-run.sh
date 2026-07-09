#!/bin/bash -e

# aircast-siyi: SIYI camera <-> MAVLink bridge. Polls the SIYI gimbal camera
# over its UDP protocol and presents it on the mavp2p endpoint as MAVLink
# camera (compid 100) + gimbal (compid 154) components, so any GCS can drive
# pan/tilt/zoom/capture. Heartbeats are gated on camera liveness, so images
# built with this stage are safe on devices without a SIYI camera attached —
# the components simply never appear.
#
# Two install paths, mirroring 11-install-aircastd:
#   * Local dev — if files/aircast-siyi (a locally-built arm64 binary,
#     gitignored; injected by build-local.sh) is present, bake it in with the
#     shipped unit + defaults.
#   * Default — install from the shared aircast-apt S3 repository under the
#     "aircast-siyi" prefix. The .deb carries the binary, the unit and
#     /etc/default/aircast-siyi, and enables itself.

LOCAL_BIN="files/aircast-siyi"
if [ -f "${LOCAL_BIN}" ]; then
	echo "aircast-siyi: baking locally-built binary (${LOCAL_BIN}); skipping S3 apt repo"
	install -m 755 "${LOCAL_BIN}" "${ROOTFS_DIR}/usr/local/bin/aircast-siyi"
	install -m 644 files/aircast-siyi.service "${ROOTFS_DIR}/etc/systemd/system/aircast-siyi.service"
	install -m 644 files/aircast-siyi.default "${ROOTFS_DIR}/etc/default/aircast-siyi"
	on_chroot << 'EOF'
systemctl enable aircast-siyi.service
EOF
	exit 0
fi

AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
AIRCAST_APT_KEY_URL="https://aircast-apt.s3.us-east-1.amazonaws.com/public-key.gpg"
AIRCAST_SIYI_APT_BASE="https://aircast-apt.s3.us-east-1.amazonaws.com/aircast-siyi"

# aircast-siyi is optional and may not be published to every channel yet.
# A missing channel must SKIP this stage, not abort the image build: adding
# a sources.list entry whose Release file 404s makes apt-get update (and
# every later apt use in the chroot) hard-fail under set -e.
if ! curl -fsIL --retry 3 --retry-delay 2 --connect-timeout 30 \
	"${AIRCAST_SIYI_APT_BASE}/dists/${AIRCAST_DISTRIBUTION}/Release" >/dev/null 2>&1; then
	echo "aircast-siyi: no '${AIRCAST_DISTRIBUTION}' channel at ${AIRCAST_SIYI_APT_BASE}; skipping (image will not include aircast-siyi)"
	exit 0
fi

# Signing key (ASCII-armored) -> dearmored rootfs keyring. Shared with the
# other aircast stages; whichever stage runs first installs it.
install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
if [ ! -f "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg" ]; then
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
		"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"
fi

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_SIYI_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast-siyi.list"

# Pin to the exact released version so the image is deterministic; falls back
# to channel-latest when no version is provided. Same tag->deb mapping as the
# aircastd stage (v0.0.1-dev.3 -> 0.0.1~dev.3).
deb_version() { local v="${1#v}"; echo "${v/-/\~}"; }

if [ -n "${AIRCAST_SIYI_VERSION:-}" ]; then
	siyi_pkg="aircast-siyi=$(deb_version "${AIRCAST_SIYI_VERSION}")"
	echo "aircast-siyi: pinning to ${siyi_pkg}"
else
	siyi_pkg="aircast-siyi"
	echo "aircast-siyi: no version pin; installing channel-latest"
fi

on_chroot << EOF
set -e
# aircast-siyi's postinst runs \`systemctl daemon-reload\` and \`systemctl
# restart\` unconditionally, which fail in the build chroot (no running
# systemd) and would abort \`apt-get install\`. Divert systemctl to a no-op
# for the install, then enable the unit offline afterwards.
dpkg-divert --local --rename --add /usr/bin/systemctl
ln -sf /bin/true /usr/bin/systemctl

apt-get update
# Quote the pin: pre-release deb versions contain a tilde (e.g. 0.2.1~dev.2)
# which the shell would otherwise tilde-expand (~ -> /root), corrupting it.
apt-get install -y --allow-downgrades "${siyi_pkg}"

rm -f /usr/bin/systemctl
dpkg-divert --local --rename --remove /usr/bin/systemctl

systemctl enable aircast-siyi.service
EOF
