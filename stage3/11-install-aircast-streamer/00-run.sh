#!/bin/bash -e

# aircast-streamer: the WHIP publisher that pushes a local RTSP camera to the
# SFU over WebRTC. It ships as a plain binary — no systemd unit; aircastd
# spawns and supervises one instance per publishing camera, resolving it by
# bare name on PATH (/usr/local/bin). This stage runs before
# 11-install-aircastd (lexical order) so the companion is always in place.
#
# Two install paths, mirroring 11-install-aircastd:
#   * Local dev — if files/aircast-streamer (a locally-built arm64 binary,
#     gitignored) is present, bake it straight in; injected by build-local.sh.
#   * Default — install from the shared aircast-apt S3 repository under the
#     "aircast-streamer" prefix. The .deb carries only the binary (no
#     maintainer scripts), so no systemctl diversion is needed here.

LOCAL_BIN="files/aircast-streamer"
if [ -f "${LOCAL_BIN}" ]; then
	echo "aircast-streamer: baking locally-built binary (${LOCAL_BIN}); skipping S3 apt repo"
	install -m 755 "${LOCAL_BIN}" "${ROOTFS_DIR}/usr/local/bin/aircast-streamer"
	exit 0
fi

AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
AIRCAST_APT_KEY_URL="https://aircast-apt.s3.us-east-1.amazonaws.com/public-key.gpg"
AIRCAST_STREAMER_APT_BASE="https://aircast-apt.s3.us-east-1.amazonaws.com/aircast-streamer"

# aircast-streamer may not be published to every channel yet. A missing
# channel must SKIP this stage, not abort the image build: adding a
# sources.list entry whose Release file 404s makes apt-get update (and every
# later apt use in the chroot) hard-fail under set -e. aircastd degrades
# gracefully at runtime when the publisher binary is absent.
if ! curl -fsIL --retry 3 --retry-delay 2 --connect-timeout 30 \
	"${AIRCAST_STREAMER_APT_BASE}/dists/${AIRCAST_DISTRIBUTION}/Release" >/dev/null 2>&1; then
	echo "aircast-streamer: no '${AIRCAST_DISTRIBUTION}' channel at ${AIRCAST_STREAMER_APT_BASE}; skipping (image will not include aircast-streamer)"
	exit 0
fi

# Signing key (ASCII-armored) -> dearmored rootfs keyring. Shared with the
# aircastd stage; whichever stage runs first installs it.
install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
if [ ! -f "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg" ]; then
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
		"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"
fi

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_STREAMER_APT_BASE} ${AIRCAST_DISTRIBUTION} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast-streamer.list"

# Pin to the exact released version so the image is deterministic; falls back
# to channel-latest when no version is provided. Same tag->deb mapping as the
# aircastd stage (v0.0.1-dev.3 -> 0.0.1~dev.3).
deb_version() { local v="${1#v}"; echo "${v/-/\~}"; }

if [ -n "${AIRCAST_STREAMER_VERSION:-}" ]; then
	streamer_pkg="aircast-streamer=$(deb_version "${AIRCAST_STREAMER_VERSION}")"
	echo "aircast-streamer: pinning to ${streamer_pkg}"
else
	streamer_pkg="aircast-streamer"
	echo "aircast-streamer: no version pin; installing channel-latest"
fi

on_chroot << EOF
set -e
apt-get update
# Quote the pin: pre-release deb versions contain a tilde (e.g. 0.2.1~dev.2)
# which the shell would otherwise tilde-expand (~ -> /root), corrupting it.
apt-get install -y --allow-downgrades "${streamer_pkg}"
EOF
