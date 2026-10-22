# Contributing

This is Aircast's fork of [pi-gen](https://github.com/RPI-Distro/pi-gen), customized to build
the Raspberry Pi OS image that ships on Aircast drones. Upstream's stage-based build pipeline
(see README.md) is unchanged; the Aircast-specific pieces are `stage3`'s overlay (encryption
unlock, Wi-Fi, boot reporting over JetKVM), `justfile`, `build-local.sh`, and the release
pipeline under `.github/workflows/` and `scripts/`.

**The default branch for this fork is `lite-arm64`, not `master`.** `master` tracks upstream
pi-gen history and should not carry Aircast changes.

## Building

```bash
just build              # test your working-copy aircastd
just build v1.2.3 v0.3.4  # build against a specific aircastd version, ready to publish
```

On Apple Silicon this builds natively (arm64 host + arm64 Docker, no QEMU). The first build of
the day rebuilds every stage; later ones reuse the cached `pigen_work` base and only redo
stage3. `just reset` forces a full rebuild if a stage change isn't picking up.

`just cache` starts the apt-cacher-ng container that caches `.deb` downloads across builds —
worth running once up front.

## Making a change

Most Aircast-specific logic lives in `stage3/`'s numbered sub-stage scripts
(`NN-run.sh` / `NN-run-chroot.sh`). pi-gen silently skips any script that doesn't match that
naming exactly — `just lint-stage-scripts` catches this and runs in CI, run it locally before
pushing if you add or rename a stage script.

Iterate with `just build` against your local aircastd build; a full `just build v1.2.3 v0.3.4`
is only needed to produce something publishable.

## CI

`.github/workflows/validate.yml` runs on PRs touching `stage**`, `scripts/**`, or `justfile`:
- `just lint-stage-scripts` — stage script naming
- `just test-release` — release.sh picks the correct next version

Run both locally before opening a PR.

## Releases

Releases are tag-driven (`.github/workflows/release.yml`), not manual. Use `just release TYPE`
(`patch|minor|major|dev|stage|rc|beta`) — the tag suffix selects both the publish channel and
the aircastd apt channel baked into the image. Never push a release tag by hand.

## Commits

Keep commits scoped and imperative (`fix(overlay): ...`, `feat(kvm): ...`, `ci(release): ...`),
matching `git log` on this branch. PRs target `lite-arm64`.
