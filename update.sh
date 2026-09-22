#!/usr/bin/env bash
# Runs install.sh --update: pull the latest images, run migrations, restart.
#
# Published at https://recv.fund/update.sh:
#   bash <(curl -fsSL https://recv.fund/update.sh) [--dir <path>] [--image-tag <tag>] [--yes]
# Uses the install.sh next to this file when run from a checkout, otherwise
# fetches it from RECV_INSTALL_URL (default https://recv.fund/install.sh).
set -euo pipefail

INSTALL_URL="${RECV_INSTALL_URL:-https://recv.fund/install.sh}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

if [ -n "$here" ] && [ -f "$here/install.sh" ]; then
  exec bash "$here/install.sh" --update "$@"
fi

# stdin becomes the script; install.sh reads prompts from /dev/tty.
curl -fsSL "$INSTALL_URL" | exec bash -s -- --update "$@"
