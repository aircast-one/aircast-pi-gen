#!/usr/bin/env bash
set -euo pipefail

BUCKET="aircast-artifacts"
URL_PATH="lite"

channel_for_version() {
    case "$1" in
        *-dev.*)   echo "development downloads.dev.aircast.one" ;;
        *-stage.*) echo "staging downloads.stage.aircast.one" ;;
        *-rc.*)    echo "testing downloads.aircast.one" ;;
        *)         echo "stable downloads.aircast.one" ;;
    esac
}

valid_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(dev|stage|rc)\.[0-9]+)?$ ]]
}

if [ "${1:-}" = "--print-channel" ]; then
    valid_version "${2:?version required}" || { echo "invalid" ; exit 1; }
    channel_for_version "$2"
    exit 0
fi

VERSION="${1:?Usage: $0 <vX.Y.Z[-dev.N|-stage.N|-rc.N]> [--yes] [--force]}"
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
    echo "Expected vX.Y.Z, or vX.Y.Z with -dev.N / -stage.N / -rc.N" >&2
    exit 1
}

read -r DISTRIBUTION DOWNLOADS_DOMAIN <<< "$(channel_for_version "$VERSION")"
S3_PATH="s3://${BUCKET}/${DISTRIBUTION}/${URL_PATH}"

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

size_of() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

# Publish exactly what `build-local.sh prod` stamped — never "newest file in
# deploy/", which can be a later dev build with the wrong provenance baked in.
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
if aws s3api head-object --bucket "$BUCKET" --key "${DISTRIBUTION}/${URL_PATH}/${VERSION}/${ASSET}" >/dev/null 2>&1; then
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

# A new version may never move its own major.minor line backwards: with 0.34.1
# published, 0.34.0 is refused while 0.34.2 is fine. Older lines stay
# publishable for hotfixes; the semver sort below keeps them off "latest".
if [ -z "$REPUBLISH" ]; then
    BARE="${VERSION#v}"
    LINE="${BARE%%-*}"
    LINE="${LINE%.*}"
    HIGHEST=$(jq -r --arg line "${LINE}." \
        '[.releases[].version | ltrimstr("v") | select(startswith($line))]
         | sort_by([splits("[.-]")] | map(tonumber? // .)) | last // empty' \
        "${WORK}/existing.json")
    if [ -n "$HIGHEST" ]; then
        NEWER=$(jq -rn --arg a "$HIGHEST" --arg b "$BARE" \
            'def key: [splits("[.-]")] | map(tonumber? // .);
             ($a | key) < ($b | key)')
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

# On a --force re-release, sweep stale differently-named files only AFTER the
# new ones are up: S3 object overwrite is atomic, so downloads never 404.
if [ -n "$REPUBLISH" ]; then
    aws s3 rm --recursive "${S3_PATH}/${VERSION}/" \
        --exclude "$ASSET" --exclude "$CHECKSUM"
fi

REMOTE_SIZE=$(aws s3api head-object --bucket "$BUCKET" \
    --key "${DISTRIBUTION}/${URL_PATH}/${VERSION}/${ASSET}" \
    --query 'ContentLength' --output text)
[ "$REMOTE_SIZE" = "$IMAGE_SIZE" ] || {
    echo "Upload size mismatch: local ${IMAGE_SIZE}, remote ${REMOTE_SIZE}" >&2
    exit 1
}

jq -n \
    --arg version "$VERSION" \
    --argjson prerelease "$([ "$DISTRIBUTION" = stable ] && echo false || echo true)" \
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

# Highest version first, whatever order things were published in: a hotfix on
# an old line lands in its right place instead of becoming "latest".
jq --slurpfile new "${WORK}/new.json" \
    'def key: .version | ltrimstr("v") | [splits("[.-]")] | map(tonumber? // .);
     .releases = ([$new[0]] + [.releases[] | select(.version != $new[0].version)]
                  | sort_by(key) | reverse)' \
    "${WORK}/existing.json" > "${WORK}/releases.json"

aws s3 cp "${WORK}/releases.json" "${S3_PATH}/releases.json"

CF_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items, '${DOWNLOADS_DOMAIN}')].Id" \
    --output text)

if [ -z "$CF_ID" ] || [ "$CF_ID" = "None" ]; then
    echo "No CloudFront distribution for ${DOWNLOADS_DOMAIN}; skipping invalidation" >&2
else
    INVALIDATION=$(aws cloudfront create-invalidation --distribution-id "$CF_ID" \
        --paths "/${URL_PATH}/releases.json" "/${URL_PATH}/${VERSION}/*" \
        --query 'Invalidation.Id' --output text)
    timeout 300 aws cloudfront wait invalidation-completed \
        --distribution-id "$CF_ID" --id "$INVALIDATION" \
        || echo "Invalidation still pending: $INVALIDATION" >&2
fi

echo "Published ${VERSION} to ${DISTRIBUTION}"
echo "https://${DOWNLOADS_DOMAIN}/${URL_PATH}/${VERSION}/${ASSET}"
