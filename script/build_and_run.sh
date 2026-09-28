#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
export CLANG_MODULE_CACHE_PATH="/private/tmp/codex-call-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/codex-call-swift-cache"
CONFIGURATION=debug
if [[ "${PHONE_KIT_RELEASE:-0}" == "1" ]]; then CONFIGURATION=release; fi
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Swift Build in Xcode 27 stamps the deployment target (14.2) as the SDK,
# which makes AppKit select its old appearance. The native engine preserves
# the selected SDK while keeping the package's older deployment target.
swift build --build-system native --sdk "$MACOS_SDK_PATH" -c "$CONFIGURATION" --arch arm64 --package-path "$ROOT/native" --scratch-path "$ROOT/native/.build" --disable-sandbox
python3 - "$ROOT/native/.build/$CONFIGURATION/CallMenu" "$MACOS_SDK_VERSION" <<'PY'
import re
import subprocess
import sys

metadata = subprocess.check_output(['xcrun', 'vtool', '-show-build', sys.argv[1]], text=True)
match = re.search(r'^\s*sdk\s+([\d.]+)', metadata, re.MULTILINE)
def version(value):
    return tuple((value.split('.') + ['0', '0'])[:3])
if not match or version(match[1]) != version(sys.argv[2]):
    actual = match[1] if match else 'missing'
    raise SystemExit(f'App SDK is {actual}; expected {sys.argv[2]}. Refusing to stage a compatibility-mode build.')
print(f'App SDK verified: {match[1]}')
PY
python3 "$ROOT/script/stage_app.py"
APP="$ROOT/dist/CallMenu.app"
case "$MODE" in
  run) /usr/bin/open "$APP" ;;
  --debug) lldb -- "$APP/Contents/MacOS/CallMenu" ;;
  --verify) /usr/bin/open "$APP"; sleep 1; pgrep -x CallMenu >/dev/null ;;
  --logs|--telemetry) /usr/bin/open "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "CallMenu"' ;;
  --build-only) ;;
  *) echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2;exit 2 ;;
esac
