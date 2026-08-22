# aircast-pi-gen task runner. Run `just` to list recipes.
#
# Local Raspberry Pi image builds. Thin wrapper around ./build-local.sh, which
# does the real work; see that script and README.md for the build pipeline.
#
# On Apple Silicon the image builds NATIVELY (arm64 host + arm64 Docker), so
# there is no QEMU emulation penalty. Speedups baked in: stage3-only rebuilds
# reuse the cached stage0-2 base (pigen_work), apt-cacher-ng caches .deb
# downloads, and a locally-built aircastd is baked in instead of pulled from S3.
#
# Testing a change:  just build
# Shipping:          just build v1.2.3 v0.3.4  &&  just publish v1.2.3
# Re-releasing:      just build v1.2.3 v0.3.4  &&  just publish v1.2.3 --yes --force
#
# The first build of the day rebuilds every stage on its own; later ones reuse
# the cached base and redo stage3 only. `just reset` forces the long way round.
# build-local.sh exposes the rest of the matrix if you need it.

# Line recipes run under bash with fail-fast flags.
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

deploy_dir := "deploy"

# List available recipes
default:
    @just --list

# Build an image — bare for testing your working-copy aircastd, with a version to publish
[group('build')]
build VERSION="" AIRCASTD="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{VERSION}}" ]; then
        AIRCASTD_VERSION={{AIRCASTD}} ./build-local.sh prod {{VERSION}}
    else
        ./build-local.sh aircastd
    fi

# Upload the newest deploy/ image to the channel its version implies (--force replaces an already published version)
[group('release')]
publish VERSION *ARGS:
    ./scripts/publish-local.sh {{VERSION}} {{ARGS}}

# Start the apt-cacher-ng container (caches .deb downloads across builds)
[group('cache')]
cache:
    docker start aircast-apt-cacher >/dev/null 2>&1 || \
        docker run -d --name aircast-apt-cacher --restart=always -p 3142:3142 \
            -v aircast-apt-cache:/var/cache/apt-cacher-ng sameersbn/apt-cacher-ng

# Remove the cached build container; the next build must rebuild every stage
[group('cache')]
reset:
    docker rm -v -f pigen_work >/dev/null 2>&1 || true
    @echo "removed pigen_work — the next build rebuilds every stage"

# Show the newest built image in deploy/
[group('image')]
latest:
    @ls -t {{deploy_dir}}/*.img {{deploy_dir}}/*.img.xz 2>/dev/null | head -1 || \
        echo "no image in {{deploy_dir}}/ — run 'just build'"

# Tags drive the delivery pipeline (.github/workflows/release.yml) and the tag
# suffix picks the channel the image is published to and the aircastd apt
# channel it bakes:
#   stable: v1.2.3   dev: v1.2.3-dev.N   stage: -stage.N   rc(testing): -rc.N

# Create and push a release tag. TYPE: patch|minor|major|dev|stage|rc
[group('release')]
release TYPE:
    ./scripts/release.sh {{TYPE}}

# Check that release.sh picks the right next version (CI gate)
[group('release')]
test-release:
    ./scripts/release_test.sh

# Fail if a stage sub-script isn't named NN-run.sh / NN-run-chroot.sh (CI gate)
[group('lint')]
lint-stage-scripts:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Validating stage sub-script naming..."
    bad=$(find stage* -mindepth 2 -maxdepth 2 -type f -name '*.sh' 2>/dev/null \
        | while IFS= read -r f; do
            base=$(basename "$f")
            echo "$base" | grep -qE '^[0-9]{2}-run(-chroot)?\.sh$' || echo "$f"
        done)
    if [ -n "$bad" ]; then
        echo "ERROR: pi-gen silently skips scripts whose names do not match NN-run.sh or NN-run-chroot.sh."
        echo "Offenders:"
        echo "$bad" | sed 's/^/  - /'
        exit 1
    fi
    echo "All stage sub-scripts have valid names."
