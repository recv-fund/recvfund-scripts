#!/usr/bin/env bash
# Runs install.sh --update: move to that installer release's images, run migrations, restart.
#
# Published as a GitHub release asset:
#   bash <(curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/update.sh) [--dir <path>] [--image-tag <tag>] [--yes]
# Uses the install.sh next to this file when run from a checkout, otherwise
# fetches the latest release's install.sh (override with RECV_INSTALL_URL).
set -euo pipefail

INSTALL_URL="${RECV_INSTALL_URL:-https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

if [ -n "$here" ] && [ -f "$here/install.sh" ]; then
  exec bash "$here/install.sh" --update "$@"
fi

# stdin becomes the script; install.sh reads prompts from /dev/tty.
curl -fsSL "$INSTALL_URL" | exec bash -s -- --update "$@"
