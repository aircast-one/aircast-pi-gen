#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

setup() {
    rm -rf "$WORK/repo" "$WORK/origin.git"
    git init -q --bare "$WORK/origin.git"
    git init -q "$WORK/repo"
    cd "$WORK/repo"
    git config user.email test@example.com
    git config user.name test
    git config tag.gpgSign false
    git config tag.forceSignAnnotated false
    git config commit.gpgSign false
    git remote add origin "$WORK/origin.git"
    cp "$SCRIPT_DIR/release.sh" .
    git add -A
    git commit -qm init
    git push -q origin HEAD:master
}

tag_here() {
    git tag -a "$1" -m "$1"
    git push -q origin "$1"
}

commit() {
    git commit -q --allow-empty -m "$1"
}

expect() {
    local type=$1 want=$2 got
    got=$(./release.sh "$type" | awk '/^New version:/ { print $3 }')
    if [ "$got" = "$want" ]; then
        echo "  ok   release.sh $type -> $got"
    else
        echo "  FAIL release.sh $type -> $got (want $want)"
        failures=$((failures + 1))
    fi
}

echo "the abandoned v3 line is an ancestor but must not win"
setup
tag_here v3.0.0
commit "fork to aircast-lite"
tag_here v0.3.2
expect patch v0.3.3
setup
tag_here v3.0.0
commit "fork to aircast-lite"
tag_here v0.3.2
expect minor v0.4.0
setup
tag_here v3.0.0
commit "fork to aircast-lite"
tag_here v0.3.2
expect dev v0.3.3-dev.1

echo "suffixed releases count from the highest existing suffix, not from one"
setup
tag_here v0.3.2
tag_here v0.3.3-dev.1
tag_here v0.3.3-dev.9
expect dev v0.3.3-dev.10
expect patch v0.3.3
setup
tag_here v0.3.2
tag_here v0.3.2-stage.4
expect stage v0.3.2-stage.5
setup
tag_here v0.3.2
expect rc v0.3.3-rc.1
setup
tag_here v0.3.2
expect beta v0.3.3-beta.1
setup
tag_here v0.3.2
tag_here v0.3.3-beta.2
expect beta v0.3.3-beta.3
expect patch v0.3.3

echo "an existing tag is refused, never silently reused"
setup
tag_here v0.3.2
tag_here v0.3.3
if ./release.sh patch >/dev/null 2>&1; then
    echo "  FAIL release.sh patch overwrote the existing v0.3.3"
    failures=$((failures + 1))
else
    echo "  ok   release.sh patch refused the existing v0.3.3"
fi

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all release version checks passed"
