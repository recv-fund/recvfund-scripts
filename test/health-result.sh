#!/usr/bin/env bash
# A failed health check must produce a failed operation, without a success banner.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
OUTPUT="$(mktemp)"
trap 'rm -f -- "$OUTPUT"' EXIT
for operation in do_install do_update do_restart; do
  # The nested shell runs the real operation under errexit with external effects stubbed.
  # shellcheck disable=SC2016
  "$BASH_BIN" -c '
    source "$1"
    DIR=/nonexistent-recvfund-health-fixture
    for name in detect_os require_tools ensure_docker ensure_dir check_disk choose_network choose_database choose_ssl generate_secrets print_summary write_files fetch_images run_migrations start_services load_existing write_build_override compose prepare_caddy_update apply_caddy_update set_env_value; do
      eval "$name() { :; }"
    done
    IMAGE_TAG=0.1.16
    wait_healthy() { return 1; }
    "$2"
  ' _ "$ROOT/install.sh" "$operation" > "$OUTPUT" 2>&1 && result=0 || result=$?
  if [ "$result" -eq 0 ] || grep -Eq 'recv.fund (installed|updated|restarted)' "$OUTPUT"; then
    printf 'Failed: %s reported success after failed health check\n' "$operation" >&2
    exit 1
  fi
  printf 'Passed: %s fails when API health fails\n' "$operation"
done
