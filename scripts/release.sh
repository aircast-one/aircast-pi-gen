#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# release.sh - Create and push an image version tag
# =============================================================================
# The tag is what triggers .github/workflows/release.yml, and its suffix picks
# the channel: none = stable, -dev.N = development, -stage.N = staging,
# -rc.N = testing.
#
# Usage:
#   ./scripts/release.sh <patch|minor|major|dev|stage|rc>
# =============================================================================

TYPE="${1:?Usage: $0 <patch|minor|major|dev|stage|rc|beta>}"

git fetch --tags --quiet origin

# Nearest plain tag in *this* history, not the highest tag in the repo: the
# image line restarted at v0.1.0 when aircast-lite forked, so the abandoned
# v1/v2/v3 tags of the old agent-driven line are still ancestors of HEAD.
latest=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' 2>/dev/null \
    || echo "v0.0.0")

if [[ ! "$latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected base version: $latest" >&2
    exit 1
fi

IFS=. read -r major minor patch <<< "${latest#v}"

# One past the HIGHEST existing suffix, not a count: reusing the number of a
# deleted middle release would make consumers that sort by version prefer it
# over a newer build.
next_suffix() {
    local base="$1" kind="$2" max=0 num tag
    while read -r tag; do
        num="${tag##*-"${kind}".}"
        [[ "$num" =~ ^[0-9]+$ ]] && (( num > max )) && max=$num
    done < <(git tag -l "${base}-${kind}.*")
    echo "${base}-${kind}.$((max + 1))"
}

case "$TYPE" in
    patch) version="v${major}.${minor}.$((patch + 1))" ;;
    minor) version="v${major}.$((minor + 1)).0" ;;
    major) version="v$((major + 1)).0.0" ;;
    dev)   version=$(next_suffix "v${major}.${minor}.$((patch + 1))" dev) ;;
    rc)    version=$(next_suffix "v${major}.${minor}.$((patch + 1))" rc) ;;
    beta)  version=$(next_suffix "v${major}.${minor}.$((patch + 1))" beta) ;;
    stage) version=$(next_suffix "v${major}.${minor}.${patch}" stage) ;;
    *)
        echo "Unknown release type: $TYPE" >&2
        echo "Valid types: patch, minor, major, dev, stage, rc, beta" >&2
        exit 1
        ;;
esac

if git rev-parse "refs/tags/$version" >/dev/null 2>&1; then
    echo "Tag $version already exists — rebuild it from the Actions tab instead" >&2
    exit 1
fi

echo "Current version: $latest"
echo "New version:     $version"

git tag -a "$version" -m "Aircast Lite Image $version"
git push origin "$version"

echo "Released $version"
