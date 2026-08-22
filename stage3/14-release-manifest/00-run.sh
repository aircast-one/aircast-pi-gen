#!/bin/bash -e

# Bake a provenance manifest so any device can report exactly what it runs:
#   cat /etc/aircast-release.json
# This is the single place that ties a pi-gen image to the aircastd it carries.
#
# The aircastd version is read from the rootfs dpkg database (the source of
# truth — it can't drift from what's actually installed). The pi-gen image
# version / ref / commit come from the release workflow via the config file;
# all have local-build fallbacks so `./build.sh` off a laptop still works.

IMAGE_VERSION="${IMAGE_VERSION:-dev}"
PI_GEN_REF="${PI_GEN_REF:-unknown}"
PI_GEN_COMMIT="${PI_GEN_COMMIT:-unknown}"
AIRCAST_DISTRIBUTION="${AIRCAST_DISTRIBUTION:-development}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Version actually installed in the rootfs. Empty for local-binary dev builds
# (files/aircastd) that bypass the apt repo, so fall back to "unknown".
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
