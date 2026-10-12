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
    ./build-local.sh cache

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

# Create and push a release tag. TYPE: patch|minor|major|rc|beta
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
    hollow=$(find stage* -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9]-*' 2>/dev/null \
        | while IFS= read -r d; do
            [ -n "$(find "$d" -type f -print -quit)" ] || continue
            ls "$d" | grep -qE '^[0-9]{2}-(run(-chroot)?\.sh|packages(-nr)?|debconf|patches)$' || echo "$d"
        done)
    if [ -n "$hollow" ]; then
        echo "ERROR: sub-stage has files but no NN-run script or NN-packages — pi-gen silently skips it."
        echo "Offenders:"
        echo "$hollow" | sed 's/^/  - /'
        exit 1
    fi
    echo "All stage sub-scripts have valid names."
