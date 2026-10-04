# Releasing

An installer release and an image release share one version, X.Y.Z. The
images must exist and be public before the installer that pins them is
published.

1. **Images.** In `recvfund-server`, tag the commit and push the tag:
   `git tag vX.Y.Z && git push origin vX.Y.Z`. The `images` workflow runs the
   checks, then builds linux/amd64 and linux/arm64 images and pushes
   `ghcr.io/recv-fund/recvfund-{api,web}` with the tags `X.Y.Z`, `X.Y` and
   `latest`. Pushes to `main` publish `edge` instead.
2. **Visibility (first release only).** New GitHub Container Registry packages
   from a private repository start private. In the organisation's Packages
   page, open `recvfund-api` and `recvfund-web`, Package settings, and change
   the visibility to public. `bash test/published-images.sh X.Y.Z` must then
   succeed without any login.
3. **Installer.** In this repository set `SCRIPT_VERSION="X.Y.Z"` in
   `install.sh`, update the version in the README examples if it appears, run
   the checks in the README, commit, then `git tag vX.Y.Z && git push origin
   main vX.Y.Z`. The `release` workflow refuses the tag unless it equals
   `SCRIPT_VERSION` and the pinned images pass `test/published-images.sh`, then
   publishes `install.sh`, `update.sh` and `SHA256SUMS` as release assets.
4. **Check.** `RECV_SMOKE_IMAGE_TAG=X.Y.Z bash test/docker-smoke.sh` installs
   from the published images on a machine with Docker.

The public site (`recvfund-site`) serves a copy of `install.sh` and
`update.sh` from its `public/` directory; copy the released files there and
run its `scripts/check-installer.sh`.
