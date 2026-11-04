#!/bin/bash
set -euo pipefail

boot=${1:-$(findmnt -n -f -o TARGET -S LABEL=bootfs || true)}
dir="$boot/aircast-update"
deb="$dir/aircastd.deb"

[ -n "$boot" ] && [ -f "$deb" ] || exit 0

log() {
	echo "aircast-update: $1"
	[ -e "$boot/aircast-fight-mode" ] || echo "aircast-update: $1" >>"$boot/aircast-boot.log" || true
}

trap 'rm -rf "$dir"; sync' EXIT

if [ ! -f "$deb.sha256" ]; then
	log "skipped: no aircastd.deb.sha256"
	exit 0
fi
if [ "$(cat "$deb.sha256")" != "$(sha256sum "$deb" | cut -d' ' -f1)" ]; then
	log "skipped: hash mismatch"
	exit 0
fi

new=$(dpkg-deb -f "$deb" Version 2>/dev/null) || { log "failed: aircastd.deb is not a package"; exit 0; }
old=$(dpkg-query -W -f='${Version}' aircastd 2>/dev/null || true)
if ! dpkg --compare-versions "$new" gt "$old"; then
	log "skipped: aircastd $new is not newer than ${old:-none}"
	exit 0
fi

if out=$(SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=/dev/null \
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
	"$deb" 2>&1); then
	log "installed aircastd $new over ${old:-none}"
else
	printf '%s\n' "$out"
	log "failed: $(awk '/^ aircastd : |^E: /{sub(/^ +|^E: /, ""); print; exit}' <<<"$out")"
fi
