#!/usr/bin/env bash
# Real, disposable installation. Requires a running Docker daemon.
# Creates a disposable owner/customer/invoice; no wallet or funds are used.
#
# Default: builds the images from the sibling recvfund-server checkout.
# RECV_SMOKE_IMAGE_TAG=<version>: pulls the published images of that version
# from ghcr.io instead, after checking they can be fetched without credentials.
# Variables in container shell commands expand inside that container.
# shellcheck disable=SC2016
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${RECVFUND_SERVER_DIR:-$ROOT/../recvfund-server}"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recvfund-docker-smoke.XXXXXX")"
SMOKE_PROJECT="recvfund-smoke-$(date +%s)-$$"
SMOKE_PORT="${RECV_SMOKE_PORT:-18090}"
export COMPOSE_PROGRESS=quiet
cleanup() {
  local result=$?
  if [ "${RECV_SMOKE_KEEP:-0}" = 1 ]; then
    printf 'Retained fixture: directory=%s project=%s port=%s exit=%s\n' "$SMOKE_DIR" "$SMOKE_PROJECT" "$SMOKE_PORT" "$result"
    return "$result"
  fi
  set +e
  if [ -f "$SMOKE_DIR/docker-compose.yml" ]; then
    docker compose -p "$SMOKE_PROJECT" --env-file "$SMOKE_DIR/.env" \
      -f "$SMOKE_DIR/docker-compose.yml" --profile db down -v --remove-orphans
  fi
  rm -rf -- "$SMOKE_DIR"
  return "$result"
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
HTTP_BIND=127.0.0.1
SITE_URL_FLAG="http://127.0.0.1:$SMOKE_PORT"
IMAGE_TAG="${RECV_SMOKE_IMAGE_TAG:-$SMOKE_PROJECT}"
public_ip() { printf localhost; }
# install.sh sets an EXIT logger; the fixture owns cleanup for this process.
trap cleanup EXIT
do_install
curl -fsS --retry 10 --retry-delay 2 --retry-connrefused "http://127.0.0.1:$SMOKE_PORT/api/v1/health" > /dev/null
curl -fsS "http://127.0.0.1:$SMOKE_PORT/signup" > "$SMOKE_DIR/signup.html"
grep -q 'Create' "$SMOKE_DIR/signup.html"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/api-json" > "$SMOKE_DIR/openapi.json"
grep -q '"openapi"' "$SMOKE_DIR/openapi.json"
compose exec -T api node - create < "$ROOT/test/release-records.cjs"
compose exec -T api node -e 'require("fs").writeFileSync("uploads/smoke-persistence.txt", "retained")'
compose up -d --force-recreate api
wait_healthy
compose exec -T api node -e 'if(require("fs").readFileSync("uploads/smoke-persistence.txt", "utf8") !== "retained") process.exit(1)'
# Replaying migrations must succeed against the running install.
run_migrations

# Failed pulls must not publish a target tag or interrupt the existing API.
previous_tag="$(env_value IMAGE_TAG)"
if [ -f "$DIR/docker-compose.build.yml" ]; then mv "$DIR/docker-compose.build.yml" "$DIR/build-before-pull.yml"; fi
set +e
(set -e; SOURCE=""; IMAGE_TAG="missing-release-smoke-$$"; do_update) > "$SMOKE_DIR/pull-failure.log" 2>&1
failure_result=$?
set -e
if [ -f "$DIR/build-before-pull.yml" ]; then mv "$DIR/build-before-pull.yml" "$DIR/docker-compose.build.yml"; fi
if [ "$failure_result" -eq 0 ]; then
  die 'A missing image unexpectedly passed the update gate'
fi
[ "$(env_value IMAGE_TAG)" = "$previous_tag" ] || die 'Failed pull changed installed image tag'
curl -fsS "http://127.0.0.1:$SMOKE_PORT/api/v1/health" >/dev/null

# Pair the consistent database dump with its encryption key, without printing it.
compose stop caddy web api
mkdir -m 700 "$SMOKE_DIR/backup"
cp "$SMOKE_DIR/.env" "$SMOKE_DIR/backup/installation.env"
chmod 600 "$SMOKE_DIR/backup/installation.env"
docker compose -p "$PROJECT" --env-file "$DIR/.env" -f "$DIR/docker-compose.yml" --profile db \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl' \
  > "$SMOKE_DIR/backup/database.dump"
chmod 600 "$SMOKE_DIR/backup/database.dump"
[ -s "$SMOKE_DIR/backup/database.dump" ] || die 'Database backup was empty'
cmp -s "$SMOKE_DIR/.env" "$SMOKE_DIR/backup/installation.env" || die 'Paired configuration differs'
if [ "$(uname -s)" = Darwin ]; then
  permissions="$(stat -f '%Lp' "$SMOKE_DIR/backup/database.dump")"
else
  permissions="$(stat -c '%a' "$SMOKE_DIR/backup/database.dump")"
fi
[ "$permissions" = 600 ] || die 'Backup permissions were not restricted'
compose exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" recv_restore_smoke'
compose exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d recv_restore_smoke --exit-on-error --no-owner --no-acl' \
  < "$SMOKE_DIR/backup/database.dump"
compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d recv_restore_smoke -v ON_ERROR_STOP=1' <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM recv."Customers" WHERE "ExternalCustomerID" = 'release-smoke-customer') THEN
    RAISE EXCEPTION 'Restored customer missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM recv."Payments" WHERE "InvoiceID" = 'RELEASE-SMOKE-001' AND "AmountUsd" = 12.345678) THEN
    RAISE EXCEPTION 'Restored precise invoice missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM recv."_migrations") THEN RAISE EXCEPTION 'Migration ledger missing'; END IF;
END $$;
SQL
printf 'Passed: restricted paired backup restored real records and migration ledger\n'

IMAGE_TAG="${RECV_SMOKE_UPDATE_TAG:-$previous_tag}"
do_update
compose exec -T api node - verify < "$ROOT/test/release-records.cjs"
compose exec -T api node -e 'if(require("fs").readFileSync("uploads/smoke-persistence.txt", "utf8") !== "retained") process.exit(1)'

# A real migration error must roll back that migration and leave the app stopped.
mkdir "$SMOKE_DIR/failure"
cat > "$SMOKE_DIR/failure/9999999999999-smoke-failure.js" <<'JS'
exports.default = class {
  async up(queryRunner) {
    await queryRunner.query('CREATE TABLE recv."SmokeMustRollback" ("Value" int)');
    throw new Error('Expected release smoke migration failure');
  }
  async down() {}
};
JS
if [ -f "$DIR/docker-compose.build.yml" ]; then
  cp "$DIR/docker-compose.build.yml" "$DIR/build-before-failure.yml"
  awk -v fixture="$SMOKE_DIR/failure/9999999999999-smoke-failure.js" '
    { print }
    /^  api:$/ { print "    volumes:"; print "      - " fixture ":/repo/apps/api/dist/src/db/migrations/9999999999999-smoke-failure.js:ro" }
  ' "$DIR/build-before-failure.yml" > "$DIR/docker-compose.build.yml"
else
  cat > "$DIR/docker-compose.build.yml" <<EOF
services:
  api:
    volumes:
      - $SMOKE_DIR/failure/9999999999999-smoke-failure.js:/repo/apps/api/dist/src/db/migrations/9999999999999-smoke-failure.js:ro
EOF
fi
set +e
(set -e; SOURCE=""; do_update) > "$SMOKE_DIR/migration-failure.log" 2>&1
failure_result=$?
set -e
if [ "$failure_result" -eq 0 ]; then
  die 'Injected migration failure unexpectedly passed the update gate'
fi
grep -q 'Expected release smoke migration failure' "$SMOKE_DIR/migration-failure.log" || die 'Migration did not reach the injected failure'
for service in api web caddy; do
  [ -z "$(docker compose -p "$PROJECT" --env-file "$DIR/.env" -f "$DIR/docker-compose.yml" ps --status running -q "$service")" ] || die "$service still running after failed migration"
done
compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' <<'SQL'
DO $$ BEGIN
  IF to_regclass('recv."SmokeMustRollback"') IS NOT NULL THEN RAISE EXCEPTION 'Failed migration was not rolled back'; END IF;
END $$;
SQL
rm "$DIR/docker-compose.build.yml"
if [ -f "$DIR/build-before-failure.yml" ]; then mv "$DIR/build-before-failure.yml" "$DIR/docker-compose.build.yml"; fi
start_services
wait_healthy
compose exec -T api node - verify < "$ROOT/test/release-records.cjs"
printf 'Passed: real failed migration rolled back its writes and left application services stopped\n'
if [ -n "${RECV_SMOKE_IMAGE_TAG:-}" ]; then mode="published images $RECV_SMOKE_IMAGE_TAG"; else mode="source build"; fi
printf 'Docker smoke passed (%s): install, OpenAPI, owner/customer/invoice, backup restore, update, upload persistence, migration replay and real pull/migration failure recovery.\n' "$mode"
if [ "${RECV_SMOKE_KEEP:-0}" = 1 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'directory=%s\nproject=%s\nport=%s\n' "$SMOKE_DIR" "$SMOKE_PROJECT" "$SMOKE_PORT" >> "$GITHUB_OUTPUT"
fi
