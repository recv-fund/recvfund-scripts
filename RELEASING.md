# Releasing

Releases are automatic. Nobody tags by hand, and a released version is never
replaced.

## Server images (`recvfund-server`)

Every push to `main` that changes more than documentation (`docs/**`,
`*.md`) runs `.github/workflows/images.yml`:

1. The `version` job takes the highest `vX.Y.Z` tag and adds one to the patch
   number. It stops if that tag already exists.
2. The checks run while `ghcr.io/recv-fund/recvfund-{api,web}` are built for
   linux/amd64 and linux/arm64 and pushed as `sha-<commit>` only.
3. After both pass, the `publish` job stops if the image version already
   exists, pushes the git tag `vX.Y.Z`, copies the tested images to `X.Y.Z`,
   `X.Y` and `latest`, and creates the GitHub release.

A failed run never publishes `X.Y.Z`. If it fails after the tag was pushed,
that number stays used and the next run takes the next one. For a minor or
major version, run the workflow by hand (Actions, images, Run workflow) and
choose `minor` or `major`; that releases the current `main` under the new
number.

Installations pick the new version up on their next `--update`. No installer
release is needed for a server release, because the installer looks up the
newest version on GHCR when it runs.

## Installer (`recvfund-scripts`)

Every push to `main` that changes more than documentation runs
`.github/workflows/release.yml`: it takes the next patch version from this
repository's tags, runs the checks and the dry run, confirms the newest
images are public (`test/published-images.sh`), runs the real Docker install,
update, backup/restore and failure-recovery smoke against those images, writes the version into
`SCRIPT_VERSION` of the published copy of `install.sh`, pushes the tag and
creates the release with `install.sh`, `update.sh` and `SHA256SUMS`. A manual
run from `main` can bump the minor or major number. Dispatches from other
branches skip publication.

Pushes to `staging` run the same static checks and disposable release-image
smoke through `ci.yml`, without publishing assets or tags. Keep a staging-only
change on that branch until its promotion to `main` is authorized.

## When the Compose or Caddy template changes

`--update` does not rewrite `docker-compose.yml`. It migrates one recognized
legacy Caddy API handler, `handle /api/* {`, to `handle @api {` with the exact
matcher `@api path /api /api/* /api-json /api-yaml`. Indentation and unrelated
custom directives are preserved. An already updated matcher/handler is kept.
Unknown or ambiguous routing and invalid Caddy syntax are rejected before
services stop or migrations begin. The candidate is checked with the installed
Caddy image, then written after successful migrations with a mode-600
`Caddyfile.before-update.*` backup. Other template changes (new services,
volumes or environment keys) require manual review and must be described in
the server release notes.

## After a release

- The public site (`recvfund-site`) serves a copy of `install.sh` and
  `update.sh` from `public/`; copy them from `main` and run
  `scripts/check-installer.sh`.
- `RECV_SMOKE_IMAGE_TAG=X.Y.Z bash test/docker-smoke.sh` installs a released
  version on a machine with Docker.
- Server release pipelines can pin this public repository to an immutable
  commit, then run `RECV_SMOKE_IMAGE_TAG=<baseline> RECV_SMOKE_UPDATE_TAG=sha-<commit>
  bash test/docker-smoke.sh` to gate promotion on a real upgrade. The candidate
  tag must already exist; failed smoke must block release promotion.

## First release of a new package only

New GitHub Container Registry packages from a private repository start
private. In the organisation's Packages page, open the package, Package
settings, and change the visibility to public. `bash
test/published-images.sh X.Y.Z` must then succeed without any login.
