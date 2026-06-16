#!/usr/bin/env bash
# Note: Avoid usage of arrays as MacOS users have an older version of bash (v3.x) which does not supports arrays
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

BUILD_OPTS="$*"

# Allow user to override docker command
DOCKER=${DOCKER:-docker}

# Ensure that default docker command is not set up in rootless mode
if \
  ! ${DOCKER} ps    >/dev/null 2>&1 || \
    ${DOCKER} info 2>/dev/null | grep -q rootless \
; then
	DOCKER="sudo ${DOCKER}"
fi
if ! ${DOCKER} ps >/dev/null; then
	echo "error connecting to docker:"
	${DOCKER} ps
	exit 1
fi

CONFIG_FILE=""
if [ -f "${DIR}/config" ]; then
	CONFIG_FILE="${DIR}/config"
fi

while getopts "c:" flag
do
	case "${flag}" in
		c)
			CONFIG_FILE="${OPTARG}"
			;;
		*)
			;;
	esac
done

# Ensure that the configuration file is an absolute path
if test -x /usr/bin/realpath; then
	CONFIG_FILE=$(realpath -s "$CONFIG_FILE" || realpath "$CONFIG_FILE")
fi

# Ensure that the confguration file is present
if test -z "${CONFIG_FILE}"; then
	echo "Configuration file need to be present in '${DIR}/config' or path passed as parameter"
	exit 1
else
	# shellcheck disable=SC1090
	source ${CONFIG_FILE}
fi

CONTAINER_NAME=${CONTAINER_NAME:-pigen_work}
CONTINUE=${CONTINUE:-0}
PRESERVE_CONTAINER=${PRESERVE_CONTAINER:-0}
PIGEN_DOCKER_OPTS=${PIGEN_DOCKER_OPTS:-""}

# Support for incremental builds with cached stages
INCREMENTAL=${INCREMENTAL:-0}
SKIP_STAGES=${SKIP_STAGES:-""}

if [ -z "${IMG_NAME}" ]; then
	echo "IMG_NAME not set in 'config'" 1>&2
	echo 1>&2
exit 1
fi

# Ensure the Git Hash is recorded before entering the docker container
GIT_HASH=${GIT_HASH:-"$(git rev-parse HEAD)"}

CONTAINER_EXISTS=$(${DOCKER} ps -a --filter name="${CONTAINER_NAME}" -q)
CONTAINER_RUNNING=$(${DOCKER} ps --filter name="${CONTAINER_NAME}" -q)
if [ "${CONTAINER_RUNNING}" != "" ]; then
	echo "The build is already running in container ${CONTAINER_NAME}. Aborting."
	exit 1
fi
if [ "${CONTAINER_EXISTS}" != "" ] && [ "${CONTINUE}" != "1" ]; then
	echo "Container ${CONTAINER_NAME} already exists and you did not specify CONTINUE=1. Aborting."
	echo "You can delete the existing container like this:"
	echo "  ${DOCKER} rm -v ${CONTAINER_NAME}"
	exit 1
fi

# Modify original build-options to allow config file to be mounted in the docker container
BUILD_OPTS="$(echo "${BUILD_OPTS:-}" | sed -E 's@\-c\s?([^ ]+)@-c /config@')"

${DOCKER} build --build-arg BASE_IMAGE=debian:trixie -t pi-gen "${DIR}"

if [ "${CONTAINER_EXISTS}" != "" ]; then
  DOCKER_CMDLINE_NAME="${CONTAINER_NAME}_cont"
  DOCKER_CMDLINE_PRE="--rm"
  DOCKER_CMDLINE_POST="--volumes-from=${CONTAINER_NAME}"
else
  DOCKER_CMDLINE_NAME="${CONTAINER_NAME}"
  DOCKER_CMDLINE_PRE=""
  DOCKER_CMDLINE_POST=""
fi

# Detect cached stages for incremental builds
# Pi-gen uses work/${IMG_NAME}/stage*/rootfs structure
WORK_DIR_HOST="${DIR}/work"
INJECT_WORK=0
if [ -d "${WORK_DIR_HOST}/${IMG_NAME}/stage2/rootfs" ]; then
  echo "Found cached stage2 rootfs at ${WORK_DIR_HOST}/${IMG_NAME}/stage2/rootfs"
  INJECT_WORK=1
  INCREMENTAL=1
  # Auto-detect which stages to skip based on existing rootfs
  if [ -z "${SKIP_STAGES}" ]; then
    SKIP_STAGES=""
    for stage in stage0 stage1 stage2; do
      if [ -d "${WORK_DIR_HOST}/${IMG_NAME}/${stage}/rootfs" ]; then
        SKIP_STAGES="${SKIP_STAGES} ${stage}"
      fi
    done
    SKIP_STAGES=$(echo "${SKIP_STAGES}" | xargs)  # trim whitespace
    echo "Auto-detected stages to skip: ${SKIP_STAGES}"
  fi
fi

# Show build mode
if [ "${INCREMENTAL}" == "1" ]; then
  echo "Build mode: INCREMENTAL (skipping cached stages)"
  for stage in ${SKIP_STAGES}; do
    echo "  - Will skip: $stage"
  done
else
  echo "Build mode: FULL (all stages)"
fi

# Check if binfmt_misc is required
binfmt_misc_required=1
case $(uname -m) in
  aarch64)
    binfmt_misc_required=0
    ;;
  arm*)
    binfmt_misc_required=0
    ;;
esac

# Check if qemu-aarch64 and /proc/sys/fs/binfmt_misc are present
if [[ "${binfmt_misc_required}" == "1" ]]; then
  if ! qemu_arm=$(which qemu-aarch64) ; then
    echo "qemu-aarch64 not found (please install qemu-user-binfmt)"
    exit 1
  fi
  if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
    echo "binfmt_misc required but not mounted, trying to mount it..."
    if ! mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc ; then
        echo "mounting binfmt_misc failed"
        exit 1
    fi
    echo "binfmt_misc mounted"
  fi
  if ! grep -q "^interpreter ${qemu_arm}" /proc/sys/fs/binfmt_misc/qemu-aarch64* ; then
    # Register qemu-aarch64 for binfmt_misc
    reg="echo ':qemu-aarch64-rpi:M::"\
"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:"\
"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:"\
"${qemu_arm}:F' > /proc/sys/fs/binfmt_misc/register"
    echo "Registering qemu-aarch64 for binfmt_misc..."
    sudo bash -c "${reg}" 2>/dev/null || true
  fi
fi

trap 'echo "got CTRL+C... please wait 5s" && ${DOCKER} stop -t 5 ${DOCKER_CMDLINE_NAME}' SIGINT SIGTERM

# Use docker create + docker cp + docker start instead of bind mounts.
# Bind mounts fail in Docker-in-Docker setups (e.g., containerized runners)
# because -v paths reference the Docker daemon's host filesystem, not the
# runner's filesystem. docker cp always works from the client's filesystem.
BUILD_CMD="
    dpkg-reconfigure qemu-user-binfmt &&
    # binfmt_misc is sometimes not mounted with debian trixie image
    (mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc || true) &&
    cd /pi-gen;
    # Create SKIP files for incremental builds if SKIP_STAGES is set
    # Pi-gen checks for SKIP files in the SOURCE stage directories (stage0/, stage1/, etc.)
    if [ -n \"\${SKIP_STAGES:-}\" ]; then
      echo 'Setting up incremental build skip markers...'
      for stage in \${SKIP_STAGES}; do
        # Create SKIP in source directory (where pi-gen checks)
        touch \${stage}/SKIP
        echo \"  Created SKIP marker: \${stage}/SKIP\"
      done
    fi
    ./build.sh ${BUILD_OPTS} &&
    rsync -av work/*/build.log deploy/
"

if [ "${INJECT_WORK}" == "1" ]; then
  # Incremental build: create container, inject cached work dir via docker cp, then start.
  # This avoids bind mounts which fail in Docker-in-Docker (containerized runners)
  # where -v paths reference the daemon host's filesystem, not the runner's.
  echo "Using docker cp to inject cached stages (DinD-compatible)..."

  ${DOCKER} create \
    --name "${DOCKER_CMDLINE_NAME}" \
    --privileged \
    ${PIGEN_DOCKER_OPTS} \
    --volume "${CONFIG_FILE}":/config:ro \
    -e "GIT_HASH=${GIT_HASH}" \
    -e "SKIP_STAGES=${SKIP_STAGES}" \
    -e "AIRCAST_DISTRIBUTION=${AIRCAST_DISTRIBUTION}" \
    $DOCKER_CMDLINE_POST \
    pi-gen \
    bash -e -o pipefail -c "${BUILD_CMD}"

  # Copy cached work directory into the stopped container
  echo "Copying cached stages into container..."
  sudo tar -C "${WORK_DIR_HOST}" -cf - . | ${DOCKER} cp - "${DOCKER_CMDLINE_NAME}":/pi-gen/work/
  echo "Cached stages injected successfully"

  # Start the container and follow output
  time ${DOCKER} start -a "${DOCKER_CMDLINE_NAME}" &
  wait "$!"
else
  # Full build: no cached stages, run directly
  time ${DOCKER} run \
    $DOCKER_CMDLINE_PRE \
    --name "${DOCKER_CMDLINE_NAME}" \
    --privileged \
    ${PIGEN_DOCKER_OPTS} \
    --volume "${CONFIG_FILE}":/config:ro \
    -e "GIT_HASH=${GIT_HASH}" \
    -e "SKIP_STAGES=${SKIP_STAGES}" \
    -e "AIRCAST_DISTRIBUTION=${AIRCAST_DISTRIBUTION}" \
    $DOCKER_CMDLINE_POST \
    pi-gen \
    bash -e -o pipefail -c "${BUILD_CMD}" &
    wait "$!"
fi

# Ensure that deploy/ is always owned by calling user
echo "copying results from deploy/"
${DOCKER} cp "${CONTAINER_NAME}":/pi-gen/deploy - | tar -xf -

# Copy work directory back for caching
# Use sudo tar to preserve ownership (rootfs has various UIDs like 1000 for pi user)
echo "copying work directory from container for caching..."
${DOCKER} cp "${CONTAINER_NAME}":/pi-gen/work - | sudo tar -xf - 2>/dev/null || true

echo "copying log from container ${CONTAINER_NAME} to deploy/"
${DOCKER} logs --timestamps "${CONTAINER_NAME}" &>deploy/build-docker.log

ls -lah deploy

# cleanup
if [ "${PRESERVE_CONTAINER}" != "1" ]; then
	${DOCKER} rm -v "${CONTAINER_NAME}"
fi

echo "Done! Your image(s) should be in deploy/"
