#!/usr/bin/env bash
# I/O boundary regression: failure before promotion must not publish a new tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/recvfund-update-failure.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT
failures=0
for failure in pull migration; do
  run="$FIXTURE/$failure"
  mkdir "$run"
  printf 'IMAGE_TAG=0.1.16\n' > "$run/.env"
  chmod 600 "$run/.env"
  # shellcheck disable=SC2016
  bash -c '
    source "$1/install.sh"
    DIR="$2"; IMAGE_TAG=0.1.17
    detect_os() { :; }; load_existing() { :; }; ensure_dir() { :; }
    ensure_docker() { :; }; write_build_override() { :; }
    compose() { printf "%s\n" "$*" >> "$DIR/operations"; }
    start_services() { printf started >> "$DIR/started"; }
    wait_healthy() { :; }
    # Functions use the captured failure rather than their own positional arguments.
    failure="$3"
    fetch_images() { [ "$failure" != pull ]; }
    run_migrations() { [ "$failure" != migration ]; }
    do_update
  ' _ "$ROOT" "$run" "$failure" > "$run/output" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] || ! grep -qx 'IMAGE_TAG=0.1.16' "$run/.env" || [ -e "$run/started" ]; then
    printf 'FAIL: %s failure changed the installed version or started services\n' "$failure" >&2
    failures=$((failures + 1))
  else
    printf 'Passed: %s failure retains the installed version without starting services\n' "$failure"
  fi
  if [ "$failure" = migration ] && ! grep -qx 'stop caddy web api' "$run/operations"; then
    printf 'FAIL: migration ran without stopping the application\n' >&2
    failures=$((failures + 1))
  fi
done
[ "$failures" -eq 0 ]
