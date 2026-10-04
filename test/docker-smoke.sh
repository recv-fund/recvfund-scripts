#!/usr/bin/env bash
# Real, disposable installation. Requires a running Docker daemon.
# No owner, RPC program, SMTP recipient or webhook endpoint is configured.
#
# Default: builds the images from the sibling recvfund-server checkout.
# RECV_SMOKE_IMAGE_TAG=<version>: pulls the published images of that version
# from ghcr.io instead, after checking they can be fetched without credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${RECVFUND_SERVER_DIR:-$ROOT/../recvfund-server}"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recvfund-docker-smoke.XXXXXX")"
SMOKE_PROJECT="recvfund-smoke-$(date +%s)-$$"
SMOKE_PORT="${RECV_SMOKE_PORT:-18090}"
cleanup() {
  if [ -f "$SMOKE_DIR/docker-compose.yml" ]; then
    docker compose -p "$SMOKE_PROJECT" --env-file "$SMOKE_DIR/.env" \
      -f "$SMOKE_DIR/docker-compose.yml" --profile db down -v --remove-orphans
  fi
  rm -rf -- "$SMOKE_DIR"
}
trap cleanup EXIT
export NO_COLOR=1
# Runtime source supplies functions and consumes the fixture state below.
# shellcheck disable=SC1091,SC2034
# shellcheck source=install.sh
source "$ROOT/install.sh"
# Source mode supplies isolated names and a loopback URL, then calls the same
# install operation as the CLI. It does not alter the merchant default project.
PROJECT="$SMOKE_PROJECT"
DIR="$SMOKE_DIR"
if [ -n "${RECV_SMOKE_IMAGE_TAG:-}" ]; then
  SOURCE=""
  bash "$ROOT/test/published-images.sh" "$RECV_SMOKE_IMAGE_TAG"
else
  SOURCE="$(cd "$SERVER_DIR" && pwd)"
fi
ACTION=install
ASSUME_YES=1
NETWORK=testnet
HTTP_PORT="$SMOKE_PORT"
HTTP_PORT_SET=1
IMAGE_TAG="${RECV_SMOKE_IMAGE_TAG:-$SMOKE_PROJECT}"
public_ip() { printf localhost; }
# install.sh sets an EXIT logger; the fixture owns cleanup for this process.
trap cleanup EXIT
# Bind the fixture only on loopback; production template remains unchanged.
eval "$(declare -f render_compose | sed '1s/render_compose/render_smoke_compose/')"
render_compose() { render_smoke_compose | sed "s/'${SMOKE_PORT}:80'/'127.0.0.1:${SMOKE_PORT}:80'/"; }
do_install
curl -fsS --retry 10 --retry-delay 2 --retry-connrefused "http://127.0.0.1:$SMOKE_PORT/api/v1/health" > /dev/null
curl -fsS "http://127.0.0.1:$SMOKE_PORT/signup" > "$SMOKE_DIR/signup.html"
grep -q 'Create' "$SMOKE_DIR/signup.html"
compose exec -T api node -e 'require("fs").writeFileSync("uploads/smoke-persistence.txt", "retained")'
compose up -d --force-recreate api
wait_healthy
compose exec -T api node -e 'if(require("fs").readFileSync("uploads/smoke-persistence.txt", "utf8") !== "retained") process.exit(1)'
# Replaying migrations must succeed against the running install.
run_migrations
printf 'Docker smoke passed (%s): migrations/seeds, API health, signup, uploads persistence and migration replay.\n' \
  "${RECV_SMOKE_IMAGE_TAG:+published images $RECV_SMOKE_IMAGE_TAG}${RECV_SMOKE_IMAGE_TAG:-source build}"
