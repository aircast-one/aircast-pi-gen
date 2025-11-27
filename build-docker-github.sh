#!/usr/bin/env bash
# GitHub Actions build wrapper
# Note: Cache logic is now handled in the workflow (release.yml)
# This script just handles GitHub Actions specific setup and calls build-docker.sh
set -eu

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

# GitHub Actions has qemu setup via docker/setup-qemu-action
# Create a wrapper qemu-aarch64-static if needed
if [ -n "${GITHUB_ACTIONS:-}" ] && [ ! -f /usr/bin/qemu-aarch64-static ]; then
    echo "Setting up qemu wrapper for GitHub Actions..."
    sudo mkdir -p /usr/bin
    echo '#!/bin/sh' | sudo tee /usr/bin/qemu-aarch64-static > /dev/null
    echo 'exec qemu-aarch64 "$@"' | sudo tee -a /usr/bin/qemu-aarch64-static > /dev/null
    sudo chmod +x /usr/bin/qemu-aarch64-static
fi

# Pass through all environment variables and arguments to build-docker.sh
exec "${DIR}/build-docker.sh" "$@"
