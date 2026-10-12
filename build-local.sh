#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
	cat <<'EOF'
Build the aircast Raspberry Pi image locally.

Usage:
  ./build-local.sh [full|fast] [aircastd|s3]
  ./build-local.sh aircastd            shorthand for: fast aircastd
  ./build-local.sh prod <version>      release-equivalent build, publishable
  ./build-local.sh -h | --help

prod <version>:
  Reuses the cached base, rebuilds stage3 against the stable apt channel with
  the release provenance CI bakes in (IMAGE_VERSION / PI_GEN_REF / commit),
  xz-compressed. Pin aircastd with AIRCASTD_VERSION=vX.Y.Z; omit for
  channel-latest. Publish the result with ./scripts/publish-local.sh.

Base mode (first arg, default: fast):
  full   Clean build of all stages. Run once to seed the cached work volume
         (pigen_work); the container is kept for future fast builds.
  fast   Reuse the cached base (stage0-2), rebuild ONLY stage3 on a clean
         stage3 rootfs. Falls back to a full build when there is no base.

aircastd source (second arg, optional):
  aircastd   Build aircastd from ../aircastd (just build-pi) and bake the local
             binary in — test uncommitted aircastd without a release.
  s3         Drop the local binary; install from the aircast-apt R2 repo.
  (omitted)  Leave whatever is currently injected as-is.
EOF
}

IMG_NAME="$( . ./config >/dev/null 2>&1; echo "${IMG_NAME}" )"
CONTAINER=pigen_work
SKIP_STAGES="stage0 stage1 stage2"
AIRCASTD_SRC="${AIRCASTD_SRC:-../aircastd}"
LOCAL_AIRCASTD="stage3/11-install-aircastd/files/aircastd"
PROD_CONFIG="config-prod"
BUILD_CONFIG="${BUILD_CONFIG:-}"

cleanup_skips() { for s in $SKIP_STAGES; do rm -f "$s/SKIP"; done; }
trap cleanup_skips EXIT

ensure_apt_cache() {
	if ! docker ps --filter name=aircast-apt-cacher -q | grep -q .; then
		echo ">> starting apt-cacher-ng"
		docker start aircast-apt-cacher >/dev/null 2>&1 || \
			docker run -d --name aircast-apt-cacher --restart=always -p 3142:3142 \
				-v aircast-apt-cache:/var/cache/apt-cacher-ng \
				sameersbn/apt-cacher-ng:3.7.4-20220421 >/dev/null
	fi
}

build_and_inject_aircastd() {
	echo ">> building aircastd from ${AIRCASTD_SRC} (just build-pi)"
	( cd "${AIRCASTD_SRC}" && just build-pi )
	install -m 755 "${AIRCASTD_SRC}/dist/aircastd-linux-arm64" "${LOCAL_AIRCASTD}"
	echo ">> injected ${LOCAL_AIRCASTD}"
}

build_full() {
	ensure_apt_cache
	cleanup_skips
	docker rm -v -f "$CONTAINER" >/dev/null 2>&1 || true
	docker volume rm "${CONTAINER}_work" >/dev/null 2>&1 || true
	echo ">> FULL build (all stages); preserving container for future fast builds"
	PRESERVE_CONTAINER=1 ./build-docker.sh ${BUILD_CONFIG:+-c "$BUILD_CONFIG"}
}

has_cached_base() {
	docker ps -a --filter name="$CONTAINER" -q | grep -q . || return 1
	docker run --rm --volumes-from "$CONTAINER" pi-gen \
		test -d "/pi-gen/work/${IMG_NAME}/stage2/rootfs" >/dev/null 2>&1
}

build_fast() {
	if ! has_cached_base; then
		echo ">> no cached stage0-2 base yet — building every stage first"
		build_full
		return
	fi
	ensure_apt_cache
	echo ">> clearing stage3 work dir for a clean rebuild"
	docker run --rm --volumes-from "$CONTAINER" pi-gen \
		rm -rf "/pi-gen/work/${IMG_NAME}/stage3"
	for s in $SKIP_STAGES; do touch "$s/SKIP"; done
	echo ">> FAST build (stage0-2 skipped, stage3 only)"
	CONTINUE=1 PRESERVE_CONTAINER=1 ./build-docker.sh ${BUILD_CONFIG:+-c "$BUILD_CONFIG"}
}

build_prod() {
	local version="${1:-}"
	if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta)\.[0-9]+)?$ ]]; then
		echo "!! prod build needs a version: ./build-local.sh prod v1.2.3" >&2
		exit 1
	fi
	local channel=stable apt_channel=""
	case "$version" in
		*-rc.*)    channel=testing ;;
		*-beta.*)  channel=stable; apt_channel=testing ;;
	esac
	rm -f "${LOCAL_AIRCASTD}"
	grep -vE '^(export )?(DEPLOY_COMPRESSION|AIRCAST_DISTRIBUTION|AIRCAST_APT_CHANNEL|AIRCASTD_VERSION|IMAGE_VERSION|PI_GEN_REF|PI_GEN_COMMIT)=' config > "$PROD_CONFIG"
	{
		echo "DEPLOY_COMPRESSION=xz"
		echo "export AIRCAST_DISTRIBUTION=${channel}"
		if [ -n "$apt_channel" ]; then echo "export AIRCAST_APT_CHANNEL=${apt_channel}"; fi
		echo "export AIRCASTD_VERSION='${AIRCASTD_VERSION:-}'"
		echo "export IMAGE_VERSION='${version}'"
		echo "export PI_GEN_REF='${version}'"
		echo "export PI_GEN_COMMIT='$(git rev-parse --short HEAD)'"
	} >> "$PROD_CONFIG"
	echo ">> PROD build ${version} (channel ${channel}, aircastd ${apt_channel:-$channel}/${AIRCASTD_VERSION:-channel-latest})"
	BUILD_CONFIG="$PROD_CONFIG" build_fast

	local img
	img=$(ls -t deploy/*.img.xz deploy/*.img 2>/dev/null | head -1 || true)
	[ -n "$img" ] || { echo "!! prod build produced no image in deploy/" >&2; exit 1; }
	printf '%s %s\n' "$version" "$(basename "$img")" > deploy/.publish-version
	echo ">> stamped deploy/.publish-version: ${version} $(basename "$img")"
}

case "${1:-}" in
	-h|--help|help) usage; exit 0 ;;
	cache)          ensure_apt_cache; exit 0 ;;
esac

if [ "${1:-}" = "prod" ]; then
	build_prod "${2:-}"
	exit 0
fi

MODE="${1:-fast}"
SOURCE="${2:-}"
if [ "${MODE}" = "aircastd" ]; then MODE=fast; SOURCE=aircastd; fi

case "${SOURCE}" in
	aircastd) build_and_inject_aircastd ;;
	s3)       echo ">> reverting to the S3 binary (removing ${LOCAL_AIRCASTD})"; rm -f "${LOCAL_AIRCASTD}" ;;
	"")       : ;;
	*)        echo "unknown aircastd source: ${SOURCE}" >&2; usage; exit 1 ;;
esac

case "${MODE}" in
	full) build_full ;;
	fast) build_fast ;;
	*)    echo "unknown mode: ${MODE}" >&2; usage; exit 1 ;;
esac
