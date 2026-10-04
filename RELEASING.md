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
images are public (`test/published-images.sh`), writes the version into
`SCRIPT_VERSION` of the published copy of `install.sh`, pushes the tag and
creates the release with `install.sh`, `update.sh` and `SHA256SUMS`. A manual
run can bump the minor or major number.

## When the Compose or Caddy template changes

`--update` does not rewrite `docker-compose.yml` or `Caddyfile` on an existing
installation. A server change that needs a template change (a new service,
volume or environment key) needs the installer change merged as well, and
existing installations need the template change applied by hand; describe it
in the server release notes.

## After a release

- The public site (`recvfund-site`) serves a copy of `install.sh` and
  `update.sh` from `public/`; copy them from `main` and run
  `scripts/check-installer.sh`.
- `RECV_SMOKE_IMAGE_TAG=X.Y.Z bash test/docker-smoke.sh` installs a released
  version on a machine with Docker.

## First release of a new package only

New GitHub Container Registry packages from a private repository start
private. In the organisation's Packages page, open the package, Package
settings, and change the visibility to public. `bash
test/published-images.sh X.Y.Z` must then succeed without any login.
