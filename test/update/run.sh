#!/bin/bash
set -euo pipefail

if [ ! -e /.dockerenv ]; then
	pigen=$(cd "$(dirname "$0")/../.." && pwd)
	exec docker run --rm -v "$pigen:/pi-gen:ro" debian:trixie bash /pi-gen/test/update/run.sh
fi

UPDATE=/pi-gen/stage3/12-overlay/files/aircast-firstboot-update.sh
BOOT=/tmp/boot

apt-get update -qq >/dev/null
apt-get install -y -qq systemd >/dev/null 2>&1
rm -rf /var/lib/apt/lists/*

package() {
	local version=$1 depends=$2 root=/tmp/pkg-$1
	mkdir -p "$root/DEBIAN" "$root/usr/local/bin" "$root/etc/systemd/system"
	printf 'Package: aircastd\nVersion: %s\nArchitecture: all\nMaintainer: test <test@aircast.one>\nDepends: %s\nRecommends: rpicam-apps-lite\nDescription: test aircastd\n' \
		"$version" "$depends" >"$root/DEBIAN/control"
	printf '/etc/systemd/system/aircastd.service\n' >"$root/DEBIAN/conffiles"
	printf '#!/bin/bash\nset -e\nsystemctl daemon-reload\nsystemctl enable aircastd.service\nsystemctl restart aircastd.service\n' >"$root/DEBIAN/postinst"
	printf '#!/bin/bash\nset -e\nsystemctl stop aircastd.service || true\nsystemctl disable aircastd.service || true\n' >"$root/DEBIAN/prerm"
	printf '[Unit]\nDescription=aircastd %s\nAfter=network-online.target\n[Service]\nExecStart=/usr/local/bin/aircastd\n[Install]\nWantedBy=multi-user.target\n' \
		"$version" >"$root/etc/systemd/system/aircastd.service"
	printf '#!/bin/sh\necho %s\n' "$version" >"$root/usr/local/bin/aircastd"
	chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm" "$root/usr/local/bin/aircastd"
	dpkg-deb -b --root-owner-group "$root" "/tmp/aircastd_$version.deb" >/dev/null
}

package 1.0 "bash, systemd"
package 2.0 "bash, systemd"
package 3.0 "bash, systemd"
package 2.1 "bash, systemd, aircast-missing"
SYSTEMD_OFFLINE=1 dpkg -i /tmp/aircastd_1.0.deb >/dev/null

failures=0
check() {
	if [ "$2" = "$3" ]; then
		echo "  PASS  $1"
	else
		echo "  FAIL  $1: got '$2', want '$3'"
		failures=$((failures + 1))
	fi
}

drop() {
	mkdir -p "$BOOT/aircast-update"
	cp "/tmp/aircastd_$1.deb" "$BOOT/aircast-update/aircastd.deb"
	case "$2" in
		good) sha256sum "$BOOT/aircast-update/aircastd.deb" | cut -d' ' -f1 >"$BOOT/aircast-update/aircastd.deb.sha256" ;;
		bad) echo 0000000000000000000000000000000000000000000000000000000000000000 >"$BOOT/aircast-update/aircastd.deb.sha256" ;;
	esac
}

scenario() {
	local name=$1 want=$2 version=$3
	out=$("$UPDATE" "$BOOT" | tail -n1)
	echo "$name"
	check "logs the outcome" "$out" "$want"
	check "removes aircast-update/" "$([ -e "$BOOT/aircast-update" ] && echo present || echo gone)" gone
	check "aircastd is $version" "$(dpkg-query -W -f='${Version}' aircastd)/$(/usr/local/bin/aircastd)" "$version/$version"
	check "dpkg is consistent" "$(dpkg --audit)" ""
}

mkdir -p "$BOOT"

echo "no update on the card"
check "does nothing" "$("$UPDATE" "$BOOT")" ""
check "writes no boot log" "$(cat "$BOOT/aircast-boot.log" 2>/dev/null)" ""

drop 2.0 none
scenario "no hash file" "aircast-update: skipped: no aircastd.deb.sha256" 1.0

drop 2.0 bad
scenario "hash mismatch" "aircast-update: skipped: hash mismatch" 1.0

drop 1.0 good
scenario "same version" "aircast-update: skipped: aircastd 1.0 is not newer than 1.0" 1.0

drop 2.1 good
scenario "newer with a dependency the card lacks" \
	"aircast-update: failed: aircastd : Depends: aircast-missing but it is not installable" 1.0

echo "# edited on the device" >>/etc/systemd/system/aircastd.service
drop 2.0 good
scenario "newer, over a locally edited unit" "aircast-update: installed aircastd 2.0 over 1.0" 2.0
check "boot log records every outcome" "$(wc -l <"$BOOT/aircast-boot.log")" 5

rm -f "$BOOT/aircast-boot.log"
touch "$BOOT/aircast-fight-mode"
drop 3.0 good
scenario "newer, fight mode" "aircast-update: installed aircastd 3.0 over 2.0" 3.0
check "fight mode leaves no boot log" "$([ -e "$BOOT/aircast-boot.log" ] && echo present || echo absent)" absent

if [ "$failures" -ne 0 ]; then
	echo "$failures check(s) failed"
	exit 1
fi
echo "all checks passed"
