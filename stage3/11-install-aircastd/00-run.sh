#!/bin/bash -e

# aircastd: device control plane. Serves the landing/status page on port 80 and
# manages the mediamtx systemd unit. It replaces the old lighttpd
# welcome page (see removed stage 09-welcome-page).
#
# Two install paths:
#   * Local dev — if files/aircastd (a locally-built arm64 binary, gitignored)
#     is present, bake it straight in with the shipped unit. Lets you test an
#     uncommitted aircastd without publishing a release; see build-local.sh.
#   * Default — install from the shared, public aircast-apt R2 repository under
#     the "aircastd" prefix (the same repo aircast.one/install.sh uses on real
#     devices), so CI and clean builds need no auth to the private
#     aircast-one/aircastd GitHub repo. The .deb carries the binary AND the unit
#     and enables itself; the channel follows AIRCAST_DISTRIBUTION, so apt pulls
#     the latest aircastd published to that channel.

# Passwordless sudo for the pi user so `just deploy` and remote maintenance can
# install the binary and restart services over SSH without a password prompt.
# Installed before either path so every image gets it.
install -m 440 files/010-aircast-nopasswd "${ROOTFS_DIR}/etc/sudoers.d/010-aircast-nopasswd"

# Provision the cloud environment (read-only): the OAuth issuer selects which
# cloud (dev/prod) this device targets. aircastd reads *only* this file for it —
# nothing environment-specific is baked into the binary. Production images prefill
# the prod issuer; every other channel defaults to dev. Installed before either
# install path so every image gets it. `just deploy` overwrites this per-device.
# Issuer + derived token URL only — the client id/secret are per-device secrets and
# must NOT be baked into a shared image; they are set per device (web UI or a
# device-scoped provisioning step).
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
# Which apt channel aircastd comes from. Normally the image's own channel; a
# beta image is a production image (issuer, bucket) that deliberately carries
# testing-channel aircastd, which is the thing under test.
AIRCAST_APT_CHANNEL="${AIRCAST_APT_CHANNEL:-${AIRCAST_DISTRIBUTION}}"
AIRCAST_APT_KEY_URL="https://apt.aircast.one/public-key.gpg"
AIRCAST_APT_BASE="https://apt.aircast.one/aircastd"

# Signing key (ASCII-armored) -> dearmored rootfs keyring. Host-side curl so we
# get the retry behaviour; gpg is provided by the pi-gen build image.
install -d -m 755 "${ROOTFS_DIR}/usr/share/keyrings"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
	"${AIRCAST_APT_KEY_URL}" | gpg --dearmor -o "${ROOTFS_DIR}/usr/share/keyrings/aircast.gpg"

echo "deb [signed-by=/usr/share/keyrings/aircast.gpg] ${AIRCAST_APT_BASE} ${AIRCAST_APT_CHANNEL} main" \
	> "${ROOTFS_DIR}/etc/apt/sources.list.d/aircast.list"

# Pin to the exact released version so the image is deterministic — a later
# release to the same channel can't change what a rebuild bakes in. Map the
# release tag to its Debian package version: drop the leading 'v' and turn '-'
# into '~' (nfpm's pre-release convention, e.g. v0.0.1-dev.3 -> 0.0.1~dev.3).
# Falls back to channel-latest when no version is provided, which is the normal
# case: the image and aircastd have separate version lines, so a release only
# pins aircastd when the build was asked to.
if [ -n "${AIRCASTD_VERSION:-}" ]; then
	deb_ver="${AIRCASTD_VERSION#v}"
	# Escape the '~': bash tilde-expands an unescaped replacement string in
	# ${var/pat/~}, turning 0.2.1~dev.2 into 0.2.1/root... and breaking the pin.
	deb_ver="${deb_ver/-/\~}"
	aircastd_pkg="aircastd=${deb_ver}"
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
