#!/bin/bash -e

# aircastd: device control plane. Serves the landing/status page on port 80 and
# manages the mediamtx and mavp2p systemd units. It replaces the old lighttpd
# welcome page (see removed stage 09-welcome-page).
#
# The version baked in defaults to the pin below, but the pi-gen release workflow
# overrides AIRCASTD_VERSION from the aircastd release that triggered the build,
# so a new aircastd release flows into the image without editing this file. The
# checksum is fetched from the release's own checksums.txt and verified — there
# is no hand-maintained SHA to keep in sync.
AIRCASTD_VERSION="${AIRCASTD_VERSION:-v0.1.0}"
AIRCASTD_BASE="https://github.com/aircast-one/aircastd/releases/download/${AIRCASTD_VERSION}"
AIRCASTD_TARBALL="aircastd_${AIRCASTD_VERSION}_linux_arm64.tar.gz"

on_chroot << EOF
set -e
curl -fsSL -o "/tmp/${AIRCASTD_TARBALL}" "${AIRCASTD_BASE}/${AIRCASTD_TARBALL}"
curl -fsSL -o /tmp/aircastd.checksums "${AIRCASTD_BASE}/checksums.txt"
EXPECTED=\$(grep "  ${AIRCASTD_TARBALL}\$" /tmp/aircastd.checksums | awk '{print \$1}')
[ -n "\$EXPECTED" ] || { echo "aircastd: ${AIRCASTD_TARBALL} missing from checksums.txt" >&2; exit 1; }
echo "\${EXPECTED}  /tmp/${AIRCASTD_TARBALL}" | sha256sum -c -
tar -xzf "/tmp/${AIRCASTD_TARBALL}" -C /tmp aircastd
install -m 755 /tmp/aircastd /usr/local/bin/aircastd
rm -f "/tmp/${AIRCASTD_TARBALL}" /tmp/aircastd.checksums /tmp/aircastd
EOF

install -m 644 files/aircastd.service "${ROOTFS_DIR}/etc/systemd/system/aircastd.service"

on_chroot << EOF
systemctl enable aircastd.service
EOF
