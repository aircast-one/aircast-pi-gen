#!/bin/bash -e

IMAGE_VERSION="${IMAGE_VERSION:-dev}"
PI_GEN_REF="${PI_GEN_REF:-unknown}"
PI_GEN_COMMIT="${PI_GEN_COMMIT:-unknown}"
AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-stable}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

AIRCASTD_VERSION="$(dpkg-query --admindir="${ROOTFS_DIR}/var/lib/dpkg" \
	-W -f='${Version}' aircastd 2>/dev/null || true)"
AIRCASTD_VERSION="${AIRCASTD_VERSION:-unknown}"

cat > "${ROOTFS_DIR}/etc/aircast-release.json" <<EOF
{
  "image_version": "${IMAGE_VERSION}",
  "pi_gen_ref": "${PI_GEN_REF}",
  "pi_gen_commit": "${PI_GEN_COMMIT}",
  "aircastd_version": "${AIRCASTD_VERSION}",
  "distribution": "${AIRCAST_DISTRIBUTION}",
  "built_at": "${BUILT_AT}"
}
EOF
chmod 644 "${ROOTFS_DIR}/etc/aircast-release.json"

echo "aircast-release: image=${IMAGE_VERSION} aircastd=${AIRCASTD_VERSION} ref=${PI_GEN_REF}@${PI_GEN_COMMIT}"
