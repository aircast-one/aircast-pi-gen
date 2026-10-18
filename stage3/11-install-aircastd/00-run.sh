#!/bin/bash -e

install -m 440 files/010-aircast-nopasswd "${ROOTFS_DIR}/etc/sudoers.d/010-aircast-nopasswd"

install -d -m 755 "${ROOTFS_DIR}/etc/aircast"
case "${AIRCAST_DISTRIBUTION:-development}" in
	stable) OAUTH_ISSUER="https://api.aircast.one" ;;
	*)      OAUTH_ISSUER="https://api.dev.aircast.one" ;;
esac
printf '{"issuer":"%s","tokenUrl":"%s/v1/oauth2/token"}\n' "${OAUTH_ISSUER}" "${OAUTH_ISSUER}" \
	> "${ROOTFS_DIR}/etc/aircast/oauth.json"
echo "aircastd: provisioned cloud issuer ${OAUTH_ISSUER} (distribution: ${AIRCAST_DISTRIBUTION:-development})"

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
AIRCAST_APT_CHANNEL="${AIRCAST_APT_CHANNEL:-${AIRCAST_DISTRIBUTION}}"
AIRCAST_APT_KEY_URL="https://apt.aircast.one/public-key.gpg"
AIRCAST_APT_BASE="https://apt.aircast.one/aircastd"

install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
	"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_APT_BASE} ${AIRCAST_APT_CHANNEL} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast.list"

if [ -n "${AIRCASTD_VERSION:-}" ]; then
	deb_ver="${AIRCASTD_VERSION#v}"
	deb_ver="${deb_ver/-/\~}"
	aircastd_pkg="aircastd=${deb_ver}"
	echo "aircastd: pinning to ${aircastd_pkg}"
else
	aircastd_pkg="aircastd"
	echo "aircastd: no version pin; installing channel-latest"
fi

on_chroot << EOF
set -e
dpkg-divert --local --rename --add /usr/bin/systemctl
ln -sf /bin/true /usr/bin/systemctl

n=0
until apt-get update; do
	n=\$((n + 1))
	[ "\$n" -lt 5 ] || exit 1
	sleep 30
done
apt-get install -y --allow-downgrades "${aircastd_pkg}"

rm -f /usr/bin/systemctl
dpkg-divert --local --rename --remove /usr/bin/systemctl

systemctl enable aircastd.service
EOF
