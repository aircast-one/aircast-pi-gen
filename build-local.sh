#!/usr/bin/env bash
# Local dev helper for building the aircast Raspberry Pi image. The dev-side
# counterpart to build-docker.sh (CI uses that one); NOT used by CI.
#
# On Apple Silicon the image builds natively (arm64 host + arm64 Docker), so
# there is no QEMU emulation penalty. Speedups: an apt-cacher-ng container
# caches .deb downloads, `fast` skips re-bootstrapping Debian + the base apt
# installs, and a locally-built aircastd avoids the S3 download entirely.
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
         stage3 rootfs. Requires a prior `full`.

aircastd source (second arg, optional):
  aircastd   Build aircastd from ../aircastd (just build-pi) and bake the local
             binary in — test uncommitted aircastd without a release.
  s3         Drop the local binary; install from the aircast-apt S3 repo.
  (omitted)  Leave whatever is currently injected as-is.
EOF
}

IMG_NAME="$( . ./config >/dev/null 2>&1; echo "${IMG_NAME}" )"
CONTAINER=pigen_work
SKIP_STAGES="stage0 stage1 stage2"
AIRCASTD_SRC="${AIRCASTD_SRC:-../aircastd}"
STREAMER_SRC="${STREAMER_SRC:-../aircast-streamer}"
LOCAL_AIRCASTD="stage3/11-install-aircastd/files/aircastd"
LOCAL_STREAMER="stage3/11-install-aircast-streamer/files/aircast-streamer"
PROD_CONFIG="config-prod"
BUILD_CONFIG="${BUILD_CONFIG:-}"

cleanup_skips() { for s in $SKIP_STAGES; do rm -f "$s/SKIP"; done; }
trap cleanup_skips EXIT

# Start the host-side apt-cacher-ng container if it is not already running, so
# .deb downloads are cached across builds (APT_PROXY in ./config points at it).
ensure_apt_cache() {
	if ! docker ps --filter name=aircast-apt-cacher -q | grep -q .; then
		echo ">> starting apt-cacher-ng"
		docker start aircast-apt-cacher >/dev/null 2>&1 || \
			docker run -d --name aircast-apt-cacher --restart=always -p 3142:3142 \
				-v aircast-apt-cache:/var/cache/apt-cacher-ng sameersbn/apt-cacher-ng >/dev/null
	fi
}

# Cross-build the aircast daemons for the Pi and bake the binaries into their
# stage3 stages, so the image uses the local builds instead of pulling
# published releases from S3. Each repo builds independently via its own
# justfile (they deploy separately too); the pair is injected together here
# only because a local image build wants both of them current.
build_and_inject_aircastd() {
	# Build ALL binaries before injecting ANY: a failed build must not leave
	# a partially-injected set (e.g. a local aircastd silently paired with a
	# channel-latest streamer from apt on the next build).
	echo ">> building aircastd from ${AIRCASTD_SRC} (just build-pi)"
	( cd "${AIRCASTD_SRC}" && just build-pi )
	echo ">> building aircast-streamer from ${STREAMER_SRC} (just build-pi)"
	( cd "${STREAMER_SRC}" && just build-pi )

	install -m 755 "${AIRCASTD_SRC}/dist/aircastd-linux-arm64" "${LOCAL_AIRCASTD}"
	install -m 755 "${STREAMER_SRC}/dist/aircast-streamer-linux-arm64" "${LOCAL_STREAMER}"
	echo ">> injected ${LOCAL_AIRCASTD} + ${LOCAL_STREAMER}"
}

# Clean build of every stage. Drops any cached container and rebuilds from
# scratch, then keeps the container so later `fast` builds can reuse the base.
build_full() {
	ensure_apt_cache
	cleanup_skips
	docker rm -v -f "$CONTAINER" >/dev/null 2>&1 || true
	# On macOS build-docker.sh keeps /pi-gen/work on a named volume (virtiofs
	# bind mounts break debootstrap); a full build must start from a clean one
	# or stage0 extracts over a stale rootfs and fails.
	docker volume rm "${CONTAINER}_work" >/dev/null 2>&1 || true
	echo ">> FULL build (all stages); preserving container for future fast builds"
	PRESERVE_CONTAINER=1 ./build-docker.sh ${BUILD_CONFIG:+-c "$BUILD_CONFIG"}
}

# A container alone is not a usable base: a full build that died in stage0
# leaves one behind over an empty work volume, and skipping to stage3 on that
# fails with "Previous stage rootfs not found".
has_cached_base() {
	docker ps -a --filter name="$CONTAINER" -q | grep -q . || return 1
	docker run --rm --volumes-from "$CONTAINER" pi-gen \
		test -d "/pi-gen/work/${IMG_NAME}/stage2/rootfs" >/dev/null 2>&1
}

# Rebuild stage3 only, reusing the cached stage0-2 base from a prior full build.
build_fast() {
	ensure_apt_cache
	if ! has_cached_base; then
		echo "!! no cached stage0-2 base — run './build-local.sh full' once first" >&2
		exit 1
	fi
	# Wipe stage3's work dir so its prerun re-copies a clean rootfs from the
	# cached stage2 (prerun only copies when stage3/rootfs is absent).
	echo ">> clearing stage3 work dir for a clean rebuild"
	docker run --rm --volumes-from "$CONTAINER" pi-gen \
		rm -rf "/pi-gen/work/${IMG_NAME}/stage3"
	for s in $SKIP_STAGES; do touch "$s/SKIP"; done
	echo ">> FAST build (stage0-2 skipped, stage3 only)"
	CONTINUE=1 PRESERVE_CONTAINER=1 ./build-docker.sh ${BUILD_CONFIG:+-c "$BUILD_CONFIG"}
}

# Release-equivalent stage3: aircastd from the stable apt channel (so dpkg — and
# therefore /etc/aircast-release.json — records a real version), the provenance
# CI exports, and xz output. Anything the release workflow sets that this omits
# is a drift bug; keep the two in step.
build_prod() {
	local version="${1:-}"
	if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|stage|rc)\.[0-9]+)?$ ]]; then
		echo "!! prod build needs a version: ./build-local.sh prod v1.2.3" >&2
		exit 1
	fi
	local channel=stable
	case "$version" in
		*-dev.*)   channel=development ;;
		*-stage.*) channel=staging ;;
		*-rc.*)    channel=testing ;;
	esac
	rm -f "${LOCAL_AIRCASTD}" "${LOCAL_STREAMER}"
	grep -vE '^(export )?(DEPLOY_COMPRESSION|AIRCAST_DISTRIBUTION|AIRCASTD_VERSION|IMAGE_VERSION|PI_GEN_REF|PI_GEN_COMMIT)=' config > "$PROD_CONFIG"
	{
		echo "DEPLOY_COMPRESSION=xz"
		echo "export AIRCAST_DISTRIBUTION=${channel}"
		echo "export AIRCASTD_VERSION='${AIRCASTD_VERSION:-}'"
		echo "export IMAGE_VERSION='${version}'"
		echo "export PI_GEN_REF='${version}'"
		echo "export PI_GEN_COMMIT='$(git rev-parse --short HEAD)'"
	} >> "$PROD_CONFIG"
	echo ">> PROD build ${version} (channel ${channel}, aircastd ${AIRCASTD_VERSION:-channel-latest})"
	if has_cached_base; then
		BUILD_CONFIG="$PROD_CONFIG" build_fast
	else
		BUILD_CONFIG="$PROD_CONFIG" build_full
	fi
}

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

if [ "${1:-}" = "prod" ]; then
	build_prod "${2:-}"
	exit 0
fi

# Two independent choices: the base MODE (full|fast) and the aircastd SOURCE
# (aircastd|s3). `aircastd` alone is shorthand for the common `fast aircastd`.
MODE="${1:-fast}"
SOURCE="${2:-}"
if [ "${MODE}" = "aircastd" ]; then MODE=fast; SOURCE=aircastd; fi

case "${SOURCE}" in
	aircastd) build_and_inject_aircastd ;;
	s3)       echo ">> reverting to S3 binaries (removing ${LOCAL_AIRCASTD} + ${LOCAL_STREAMER}; the streamer stage skips channels with no published release)"; rm -f "${LOCAL_AIRCASTD}" "${LOCAL_STREAMER}" ;;
	"")       : ;;
	*)        echo "unknown aircastd source: ${SOURCE}" >&2; usage; exit 1 ;;
esac

case "${MODE}" in
	full) build_full ;;
	fast) build_fast ;;
	*)    echo "unknown mode: ${MODE}" >&2; usage; exit 1 ;;
esac
