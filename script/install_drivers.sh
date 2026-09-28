#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# == 1 && "$1" == --check ]]; then
    exec "$ROOT/dist/CallMenu.app/Contents/Library/LaunchServices/com.codexcall.phonekit.helper" --check
fi
echo "Open Phone Assistant and choose Enable Phone Assistant Audio Bridge in Setup. Installation is bundled in the app."
echo "For read-only checks: $0 --check"
exit 2
