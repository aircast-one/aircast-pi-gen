#!/usr/bin/env bash
set -euo pipefail

URL_PATH="lite"

export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-https://cb3f7d95c2d311b22c4e57e0759d3a13.r2.cloudflarestorage.com}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"

channel_for_version() {
    case "$1" in
        *-dev.*)   echo "development downloads-dev.aircast.one" ;;
        *-stage.*) echo "staging downloads-stage.aircast.one" ;;
        *-rc.*)    echo "testing downloads.aircast.one" ;;
        *-beta.*)  echo "stable downloads.aircast.one" ;;
        *)         echo "stable downloads.aircast.one" ;;
    esac
}

valid_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|stage|rc|beta)\.[0-9]+)?$ ]]
}

if [ "${1:-}" = "--print-channel" ]; then
    valid_version "${2:?version required}" || { echo "invalid" ; exit 1; }
    channel_for_version "$2"
    exit 0
fi

VERSION="${1:?Usage: $0 <vX.Y.Z[-dev.N|-stage.N|-rc.N|-beta.N]> [--yes] [--force]}"
shift
ASSUME_YES=""
FORCE=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   ASSUME_YES="--yes" ;;
        --force|-f) FORCE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

valid_version "$VERSION" || {
    echo "Invalid version: $VERSION" >&2
    echo "Expected vX.Y.Z, or vX.Y.Z with -dev.N / -stage.N / -rc.N / -beta.N" >&2
    exit 1
}

read -r DISTRIBUTION DOWNLOADS_DOMAIN <<< "$(channel_for_version "$VERSION")"
BUCKET="aircast-artifacts-${DISTRIBUTION}"
S3_PATH="s3://${BUCKET}/${URL_PATH}"

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

size_of() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

# shellcheck disable=SC2016
SEMVER_KEY='def semver_key:
    split("-") as $parts
    | ($parts[0] | split(".") | map(tonumber)) as $core
    | (if ($parts | length) > 1
       then [0, ($parts[1:] | join("-") | split(".") | map(tonumber? // .))]
       else [1, []] end) as $pre
    | [$core[0], $core[1], $core[2], $pre[0], $pre[1]];'

DEPLOY_DIR="${DEPLOY_DIR:-deploy}"
MARKER="${DEPLOY_DIR}/.publish-version"
[ -f "$MARKER" ] || { echo "No ${MARKER} — run 'just build ${VERSION}' first" >&2; exit 1; }
read -r BUILT_VERSION BUILT_IMAGE < "$MARKER"
[ "$BUILT_VERSION" = "$VERSION" ] || {
    echo "deploy/ holds a ${BUILT_VERSION} build, not ${VERSION} — rebuild with 'just build ${VERSION}'" >&2
    exit 1
}
IMAGE_PATH="${DEPLOY_DIR}/${BUILT_IMAGE}"
[ -f "$IMAGE_PATH" ] || { echo "${IMAGE_PATH} from ${MARKER} is gone — rebuild with 'just build ${VERSION}'" >&2; exit 1; }

case "$IMAGE_PATH" in
    *.img.xz) EXT="img.xz" ;;
    *.img.gz) EXT="img.gz" ;;
    *.img)    EXT="img" ;;
    *.zip)    EXT="zip" ;;
    *)        EXT="${IMAGE_PATH##*.}" ;;
esac

ASSET="aircast-lite-arm64-${VERSION}.${EXT}"
CHECKSUM="${ASSET}.sha256"

echo "Image:        $IMAGE_PATH"
echo "Publishing:   $ASSET"
echo "Channel:      $DISTRIBUTION"
echo "Destination:  ${S3_PATH}/${VERSION}/"
echo "Download URL: https://${DOWNLOADS_DOMAIN}/${URL_PATH}/${VERSION}/${ASSET}"

if [ "$DISTRIBUTION" = "stable" ] && [ "$ASSUME_YES" != "--yes" ]; then
    echo
    echo "This publishes a LOCALLY BUILT image to PRODUCTION. It has no git tag,"
    echo "no GitHub Release, and no CI provenance behind it."
    read -r -p "Type the version to confirm: " reply
    [ "$reply" = "$VERSION" ] || { echo "Aborted." >&2; exit 1; }
fi

REPUBLISH=""
if aws s3api head-object --bucket "$BUCKET" --key "${URL_PATH}/${VERSION}/${ASSET}" >/dev/null 2>&1; then
    if [ -z "$FORCE" ]; then
        echo "Refusing to overwrite an already published ${VERSION}. Re-release with --force, or pick a new version." >&2
        exit 1
    fi
    echo "Replacing already published ${VERSION} (--force)"
    REPUBLISH=1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

aws s3 cp "${S3_PATH}/releases.json" "${WORK}/existing.json" 2>/dev/null \
    || echo '{"releases":[]}' > "${WORK}/existing.json"

if [ -z "$REPUBLISH" ]; then
    BARE="${VERSION#v}"
    LINE="${BARE%%-*}"
    LINE="${LINE%.*}"
    HIGHEST=$(jq -r --arg line "${LINE}." "${SEMVER_KEY}"'
        [.releases[].version | ltrimstr("v") | select(startswith($line))]
         | sort_by(semver_key) | last // empty' \
        "${WORK}/existing.json")
    if [ -n "$HIGHEST" ]; then
        NEWER=$(jq -rn --arg a "$HIGHEST" --arg b "$BARE" "${SEMVER_KEY}"'
             ($a | semver_key) < ($b | semver_key)')
        if [ "$NEWER" != "true" ]; then
            echo "Refusing to publish ${VERSION}: the ${LINE} line is already at ${HIGHEST}. Only a higher ${LINE}.x may be published." >&2
            exit 1
        fi
    fi
fi

cp "$IMAGE_PATH" "${WORK}/${ASSET}"
( cd "$WORK" && sha256_of "$ASSET" > "$CHECKSUM" )

IMAGE_SIZE=$(size_of "${WORK}/${ASSET}")
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

aws s3 cp "${WORK}/${ASSET}"    "${S3_PATH}/${VERSION}/${ASSET}"
aws s3 cp "${WORK}/${CHECKSUM}" "${S3_PATH}/${VERSION}/${CHECKSUM}"

if [ -n "$REPUBLISH" ]; then
    aws s3 rm --recursive "${S3_PATH}/${VERSION}/" \
        --exclude "$ASSET" --exclude "$CHECKSUM"
fi

REMOTE_SIZE=$(aws s3api head-object --bucket "$BUCKET" \
    --key "${URL_PATH}/${VERSION}/${ASSET}" \
    --query 'ContentLength' --output text)
[ "$REMOTE_SIZE" = "$IMAGE_SIZE" ] || {
    echo "Upload size mismatch: local ${IMAGE_SIZE}, remote ${REMOTE_SIZE}" >&2
    exit 1
}

jq -n \
    --arg version "$VERSION" \
    --argjson prerelease "$([[ "$VERSION" == *-* ]] && echo true || echo false)" \
    --arg created_at "$CREATED_AT" \
    --arg filename "$ASSET" \
    --arg extension "$EXT" \
    --argjson size "$IMAGE_SIZE" \
    --arg download_url "https://${DOWNLOADS_DOMAIN}/${URL_PATH}/${VERSION}/${ASSET}" \
    --arg checksum_url "https://${DOWNLOADS_DOMAIN}/${URL_PATH}/${VERSION}/${CHECKSUM}" \
    '{version: $version, prerelease: $prerelease, created_at: $created_at,
      image: {filename: $filename, extension: $extension, size: $size,
              download_url: $download_url, checksum_url: $checksum_url}}' \
    > "${WORK}/new.json"

jq --slurpfile new "${WORK}/new.json" "${SEMVER_KEY}"'
     .releases = ([$new[0]] + [.releases[] | select(.version != $new[0].version)]
                  | sort_by(.version | ltrimstr("v") | semver_key) | reverse)' \
    "${WORK}/existing.json" > "${WORK}/releases.json"

aws s3 cp "${WORK}/releases.json" "${S3_PATH}/releases.json"

echo "Published ${VERSION} to ${DISTRIBUTION}"
echo "https://${DOWNLOADS_DOMAIN}/${URL_PATH}/${VERSION}/${ASSET}"
