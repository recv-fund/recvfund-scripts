#!/usr/bin/env bash
# A proxy page or an unhealthy JSON document must not pass the health gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for body in '<html>maintenance</html>' '{"status":"error"}' '{"status":"ok","details":{}}'; do
  # shellcheck disable=SC2016
  bash -c '
    source "$1/install.sh"
    HEALTH_TIMEOUT=1; SSL_MODE=http; HTTP_PORT=18090
    response="$2"
    curl() { printf "%s" "$response"; }
    sleep() { :; }
    wait_healthy
  ' _ "$ROOT" "$body" >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ "$body" == *'"status":"ok"'* ]]; then
    [ "$rc" -eq 0 ] || { printf 'FAIL: healthy API rejected\n' >&2; exit 1; }
  else
    [ "$rc" -ne 0 ] || { printf 'FAIL: non-healthy response accepted\n' >&2; exit 1; }
  fi
done
printf 'Passed: health requires an explicit healthy status\n'
