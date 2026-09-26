#!/usr/bin/env bash
# Dry-run test for install.sh. Runs the installer with RECV_DRY_RUN=1 (docker
# commands are printed, not executed) and checks the written files.
#
#   bash test/dry-run.sh
#
# Needs bash 4+ on PATH as `bash`, or set BASH_BIN. Set RECVFUND_SERVER_DIR
# to a recvfund-server checkout to also diff the rendered docker-compose.yml
# and Caddyfile against the repo copies (defaults to the sibling directory).
# Assertions use always-successful reporting functions; nested bash and template
# patterns deliberately contain literal variable syntax.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

BASH_BIN="${BASH_BIN:-bash}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
DIR="$(mktemp -d "${RECV_TEST_DIR:-${TMPDIR:-/tmp}}/recvfund-test.XXXXXX")"
trap 'rm -rf -- "$DIR"' EXIT
SERVER_DIR="${RECVFUND_SERVER_DIR:-$ROOT/../recvfund-server}"
failures=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

assert_grep() { # assert_grep <file> <regex> <label>
  if grep -Eq -- "$2" "$1"; then pass "$3"; else fail "$3 (expected pattern missing)"; fi
}
assert_not_grep() {
  if grep -Eq -- "$2" "$1"; then fail "$3 (unexpected pattern present)"; else pass "$3"; fi
}

run_installer() { # run_installer <output-file> <args...>
  local out="$1"; shift
  RECV_DRY_RUN=1 NO_COLOR=1 "$BASH_BIN" "$INSTALL" "$@" > "$out" 2>&1 </dev/null || {
    printf 'install.sh exited non-zero. Output:\n'; cat "$out"; exit 1
  }
}

major="$("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}')"
if [ "$major" -lt 4 ]; then
  printf '%s is bash %s; install.sh needs bash 4+. Set BASH_BIN (for example /opt/homebrew/bin/bash).\n' "$BASH_BIN" "$major" >&2
  exit 1
fi

OUT1="$DIR/run1.out"

printf 'Fresh install, testnet, bundled db, plain HTTP on 8080\n'
run_installer "$OUT1" --yes --testnet --dir "$DIR" --http-port 8080

[ -f "$DIR/.env" ] && pass ".env written" || fail ".env missing"
[ -f "$DIR/docker-compose.yml" ] && pass "docker-compose.yml written" || fail "docker-compose.yml missing"
[ -f "$DIR/Caddyfile" ] && pass "Caddyfile written" || fail "Caddyfile missing"
[ -f "$DIR/install.log" ] && pass "install.log written" || fail "install.log missing"

perm="$(stat -f '%Lp' "$DIR/.env" 2>/dev/null || stat -c '%a' "$DIR/.env")"
[ "$perm" = 600 ] && pass ".env mode 600" || fail ".env mode is $perm"

for key in SITE_DOMAIN ACME_EMAIL SITE_URL NETWORK_TYPE AES_ENCRYPTION_KEY ADMIN_API_KEY \
           POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_SSL \
           REDIS_PASSWORD SEND_WEBHOOKS IMAGE_TAG; do
  assert_grep "$DIR/.env" "^${key}=" ".env has $key"
done
assert_grep "$DIR/.env" "^SITE_DOMAIN=:80$" "SITE_DOMAIN is :80"
assert_grep "$DIR/.env" "^ACME_EMAIL=$" "ACME_EMAIL is empty"
assert_grep "$DIR/.env" "^SITE_URL=http://localhost:8080$" "SITE_URL defaults to http://localhost:8080"
assert_grep "$DIR/.env" "^NETWORK_TYPE=testnet " "NETWORK_TYPE is testnet"
assert_grep "$DIR/.env" "^AES_ENCRYPTION_KEY=[0-9a-f]{64}$" "AES_ENCRYPTION_KEY is 64 hex chars"
assert_grep "$DIR/.env" "^ADMIN_API_KEY=[0-9a-f]{48}$" "ADMIN_API_KEY is 48 hex chars"
assert_grep "$DIR/.env" "^POSTGRES_PASSWORD=[0-9a-f]{48}$" "POSTGRES_PASSWORD is 48 hex chars"
assert_grep "$DIR/.env" "^REDIS_PASSWORD=[0-9a-f]{48}$" "REDIS_PASSWORD is 48 hex chars"
assert_grep "$DIR/.env" "^POSTGRES_HOST=postgres$" "POSTGRES_HOST is the bundled container"
assert_grep "$DIR/.env" "^IMAGE_TAG=latest$" "IMAGE_TAG is latest"

assert_grep "$DIR/docker-compose.yml" "^      - '8080:80'$" "caddy maps host port 8080"
assert_not_grep "$DIR/docker-compose.yml" "443" "no 443 mapping in HTTP mode"
assert_grep "$DIR/docker-compose.yml" "ghcr.io/recvfund/recvfund-api:\\\$\\{IMAGE_TAG:-latest\\}" "api image reference"
assert_grep "$DIR/docker-compose.yml" "ghcr.io/recvfund/recvfund-web:\\\$\\{IMAGE_TAG:-latest\\}" "web image reference"
assert_grep "$DIR/docker-compose.yml" "profiles: \\['db'\\]" "postgres service has the db profile"
assert_grep "$DIR/docker-compose.yml" "node dist|api:" "api service present"

assert_grep "$DIR/Caddyfile" '^\{\$SITE_DOMAIN\} \{$' "Caddyfile site block uses SITE_DOMAIN"
assert_grep "$DIR/Caddyfile" "reverse_proxy api:3001" "Caddyfile routes /api to api"
assert_grep "$DIR/Caddyfile" "reverse_proxy web:3000" "Caddyfile routes / to web"
assert_not_grep "$DIR/Caddyfile" "ACME_EMAIL" "Caddyfile has no email option in HTTP mode"

aes="$(grep -E '^AES_ENCRYPTION_KEY=' "$DIR/.env" | cut -d= -f2)"
assert_not_grep "$OUT1" "$aes" "AES key not printed"
assert_not_grep "$DIR/install.log" "$aes" "AES key not logged"
assert_grep "$OUT1" "\\[dry-run\\] docker compose -p recvfund --env-file $DIR/.env -f $DIR/docker-compose.yml --profile db pull" "pull command with db profile"
assert_grep "$OUT1" "--profile db up -d --wait postgres redis" "bundled postgres started before migrate"
assert_grep "$OUT1" "run --rm api node dist/src/db/migrate" "migrate command"
assert_grep "$OUT1" "--profile db up -d --remove-orphans" "up -d command"
assert_grep "$OUT1" "would poll http://127.0.0.1:8080/api/v1/health" "health poll on the http port"
assert_grep "$OUT1" "recv.fund installed" "success banner"
assert_grep "$OUT1" "http://localhost:8080/signup" "signup URL printed"
assert_grep "$OUT1" "AES_ENCRYPTION_KEY" "backup reminder printed"

printf 'Re-run of the same command routes to update and keeps .env\n'
sum_before="$(cksum "$DIR/.env")"
OUT2="$DIR/run2.out"
run_installer "$OUT2" --yes --testnet --dir "$DIR" --http-port 8080
[ "$(cksum "$DIR/.env")" = "$sum_before" ] && pass ".env unchanged" || fail ".env changed on re-run"
assert_grep "$OUT2" "An installation already exists" "existing install detected"
assert_grep "$OUT2" "recv.fund updated" "update completed"

printf -- '--update, --restart, --status\n'
OUT3="$DIR/run3.out"
run_installer "$OUT3" --update --yes --dir "$DIR" --image-tag v1.2.3
assert_grep "$DIR/.env" "^IMAGE_TAG=v1.2.3$" "--update --image-tag rewrites IMAGE_TAG"
assert_grep "$OUT3" "--profile db pull" "update pulls"
assert_grep "$OUT3" "run --rm api node dist/src/db/migrate" "update migrates"
run_installer "$OUT3" --restart --yes --dir "$DIR"
assert_grep "$OUT3" "--profile db restart" "restart command"
run_installer "$OUT3" --status --yes --dir "$DIR"
assert_grep "$OUT3" "--profile db ps" "status runs ps"
assert_grep "$OUT3" "would request http://127.0.0.1:8080/api/v1/health" "status requests health"

printf 'Let'"'"'s Encrypt mode with an external database and --source\n'
DIR2="$DIR/le"
mkdir -p "$DIR2"
OUT4="$DIR/run4.out"
if [ -d "$SERVER_DIR/apps/api" ]; then
  src_flag=(--source "$SERVER_DIR")
else
  src_flag=()
fi
if [ "$(uname -s)" = Darwin ]; then
  # Let's Encrypt is refused on macOS; render the files by pretending to be Linux is not
  # possible, so only assert the refusal here and render LE files via HTTP_PORT-less path elsewhere.
  RECV_DRY_RUN=1 NO_COLOR=1 "$BASH_BIN" "$INSTALL" --yes --mainnet --dir "$DIR2" --domain pay.example.com --email ops@example.com \
    --pg-host db.internal --pg-port 5433 --pg-db shop --pg-user shop --pg-password 'p#ss' "${src_flag[@]}" > "$OUT4" 2>&1 </dev/null && rc=0 || rc=$?
  [ "$rc" -ne 0 ] && pass "Let's Encrypt refused on macOS" || fail "Let's Encrypt accepted on macOS"
  assert_grep "$OUT4" "not available on macOS" "macOS refusal message"
else
  run_installer "$OUT4" --yes --mainnet --dir "$DIR2" --domain pay.example.com --email ops@example.com \
    --pg-host db.internal --pg-port 5433 --pg-db shop --pg-user shop --pg-password 'p#ss' "${src_flag[@]}"
  assert_grep "$DIR2/.env" "^SITE_DOMAIN=pay.example.com$" "SITE_DOMAIN is the domain"
  assert_grep "$DIR2/.env" "^SITE_URL=https://pay.example.com$" "SITE_URL is https"
  assert_grep "$DIR2/.env" "^NETWORK_TYPE=mainnet " "NETWORK_TYPE is mainnet"
  assert_grep "$DIR2/.env" "^POSTGRES_HOST=db.internal$" "external POSTGRES_HOST"
  assert_grep "$DIR2/.env" "^POSTGRES_PORT=5433$" "external POSTGRES_PORT"
  assert_grep "$DIR2/.env" "^POSTGRES_PASSWORD=p#ss$" "external password written verbatim"
  assert_not_grep "$OUT4" "p#ss" "external password not printed"
  assert_grep "$DIR2/docker-compose.yml" "^      - '443:443/udp'$" "443 mapping kept in LE mode"
  assert_grep "$DIR2/Caddyfile" 'email \{\$ACME_EMAIL\}' "Caddyfile keeps the email option in LE mode"
  assert_not_grep "$OUT4" "--profile db" "no db profile with an external database"
  assert_grep "$OUT4" "pg_isready -h db.internal -p 5433 -U shop -d shop" "pg_isready connectivity test"
  if [ -d "$SERVER_DIR/apps/api" ]; then
    diff -q "$DIR2/docker-compose.yml" "$SERVER_DIR/docker-compose.prod.yml" >/dev/null && pass "docker-compose.yml identical to repo" || fail "docker-compose.yml differs from repo"
    diff -q "$DIR2/Caddyfile" "$SERVER_DIR/deploy/Caddyfile" >/dev/null && pass "Caddyfile identical to repo" || fail "Caddyfile differs from repo"
    assert_grep "$DIR2/docker-compose.build.yml" "dockerfile: apps/api/Dockerfile" "build override written for --source"
    assert_grep "$OUT4" "build --pull" "--source builds instead of pulling"
  fi
fi

printf 'Template check: rendered files match the repo copies (needs RECVFUND_SERVER_DIR)\n'
if [ -d "$SERVER_DIR/apps/api" ]; then
  # Render the templates in Let's Encrypt mode without going through the OS check.
  tmp="$DIR/templates"
  mkdir -p "$tmp"
  "$BASH_BIN" -c '
    set -euo pipefail
    source "$1"
    SSL_MODE=letsencrypt; HTTP_PORT=80
    render_compose > "$2/docker-compose.yml"
    render_caddyfile > "$2/Caddyfile"
  ' _ "$INSTALL" "$tmp"
  diff -q "$tmp/docker-compose.yml" "$SERVER_DIR/docker-compose.prod.yml" >/dev/null && pass "embedded docker-compose.yml identical to docker-compose.prod.yml" || { fail "embedded docker-compose.yml differs from repo"; diff "$tmp/docker-compose.yml" "$SERVER_DIR/docker-compose.prod.yml" || true; }
  diff -q "$tmp/Caddyfile" "$SERVER_DIR/deploy/Caddyfile" >/dev/null && pass "embedded Caddyfile identical to deploy/Caddyfile" || { fail "embedded Caddyfile differs from repo"; diff "$tmp/Caddyfile" "$SERVER_DIR/deploy/Caddyfile" || true; }
  # .env: same keys, same order, same comments as deploy/.env.example.
  if diff <(sed -E 's/=.*//' "$DIR/.env") <(sed -E 's/=.*//' "$SERVER_DIR/deploy/.env.example") >/dev/null; then
    pass ".env layout identical to deploy/.env.example"
  else
    fail ".env layout differs from deploy/.env.example"
  fi
else
  printf '  skip (no recvfund-server checkout at %s)\n' "$SERVER_DIR"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'All checks passed.\n'
else
  printf '%d check(s) failed.\n' "$failures"
  exit 1
fi
