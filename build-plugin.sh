#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
case "${1:-unsigned}" in
  unsigned) python3 tools/package_plugin.py --plugin acc-weather ;;
  signed) shift; python3 tools/package_plugin.py --plugin acc-weather --create-signing-key "$@" ;;
  *) echo 'Usage: build-plugin.sh [unsigned|signed [signing options]]' >&2; exit 2 ;;
esac
