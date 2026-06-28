# aircast-pi-gen task runner. Run `just` to list recipes.
#
# Local Raspberry Pi image builds. Thin wrapper around ./build-local.sh, which
# does the real work; see that script and README.md for the build pipeline.
#
# On Apple Silicon the image builds NATIVELY (arm64 host + arm64 Docker), so
# there is no QEMU emulation penalty. Speedups baked in: `fast` reuses the
# cached stage0-2 base (pigen_work), apt-cacher-ng caches .deb downloads, and a
# locally-built aircastd is baked straight in instead of pulled from S3.
#
# Everyday loop:  just image     (fresh local aircastd + stage3-only rebuild)
# First run:      just seed      (clean all stages once to seed the cache)

# Line recipes run under bash with fail-fast flags.
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

deploy_dir := "deploy"

# List available recipes
default:
    @just --list

# Build local aircastd + fast stage3-only rebuild — the everyday loop
[group('build')]
image:
    ./build-local.sh aircastd

# First time / base changed: clean rebuild of all stages + local aircastd
[group('build')]
seed:
    ./build-local.sh full aircastd

# Fast stage3-only rebuild, reusing the already-injected aircastd binary
[group('build')]
fast:
    ./build-local.sh fast

# Full clean rebuild of every stage (S3 aircastd unless a binary is injected)
[group('build')]
full:
    ./build-local.sh full

# Drop the local aircastd binary; rebuild against the S3 apt repo instead
[group('build')]
s3:
    ./build-local.sh fast s3

# Start the apt-cacher-ng container (caches .deb downloads across builds)
[group('cache')]
cache:
    docker start aircast-apt-cacher >/dev/null 2>&1 || \
        docker run -d --name aircast-apt-cacher --restart=always -p 3142:3142 \
            -v aircast-apt-cache:/var/cache/apt-cacher-ng aircast-apt-cacher

# Remove the cached build container; the next build must re-seed via `just seed`
[group('cache')]
reset:
    docker rm -v -f pigen_work >/dev/null 2>&1 || true
    @echo "removed pigen_work — run 'just seed' before the next build"

# Show the newest built image in deploy/
[group('image')]
latest:
    @ls -t {{deploy_dir}}/*.img.xz 2>/dev/null | head -1 || \
        echo "no image in {{deploy_dir}}/ — run 'just image'"

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
