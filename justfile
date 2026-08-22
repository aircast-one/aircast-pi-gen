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
# build*    picks WHICH aircastd goes in; rebuild* keeps what is already staged.
# *-clean   rebuilds every stage instead of stage3 alone.
#
# Testing a change:  just build
# First run:         just build-clean
# Shipping:          just build-release v1.2.3 v0.3.4 && just publish v1.2.3

# Line recipes run under bash with fail-fast flags.
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

deploy_dir := "deploy"

# List available recipes
default:
    @just --list

# Image carrying your working-copy aircastd — the everyday loop
[group('build')]
build:
    ./build-local.sh aircastd

# Same, but rebuild every stage: first run, or after the Debian base changed
[group('build')]
build-clean:
    ./build-local.sh full aircastd

# Image carrying the released aircastd from apt instead of your working copy
[group('build')]
build-from-apt:
    ./build-local.sh fast s3

# Publishable image: apt aircastd, release provenance, xz — what CI would build
[group('build')]
build-release VERSION AIRCASTD="":
    AIRCASTD_VERSION={{AIRCASTD}} ./build-local.sh prod {{VERSION}}

# Rebuild stage3 with whatever binaries are already staged
[group('build')]
rebuild:
    ./build-local.sh fast

# Rebuild every stage with whatever binaries are already staged
[group('build')]
rebuild-clean:
    ./build-local.sh full

# Upload the newest deploy/ image to the channel its version implies
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
