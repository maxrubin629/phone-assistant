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
EXECUTABLE="$APP/Contents/MacOS/CallMenu"
# `open` only activates a copy that's already running, which would keep the
# previous build alive; macOS then refuses its bridge installs.
# Asks the running app, through its bundled MCP server, whether a call is live.
call_active() {
  python3 - "$APP/Contents/MacOS/CallMCP" 2>/dev/null <<'CHECK'
import json, subprocess, sys
messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "build", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "call_get", "arguments": {}}}]
output = subprocess.run([sys.argv[1]], input="\n".join(map(json.dumps, messages)) + "\n", capture_output=True, text=True, timeout=10).stdout
for line in output.splitlines():
    response = json.loads(line)
    if response.get("id") == 2:
        sys.exit(0 if response["result"]["structuredContent"].get("audio_connected") else 1)
sys.exit(1)
CHECK
}
launch() {
  if pgrep -qxf "$EXECUTABLE"; then
    # Restarting ends any call in progress. Leave the new build staged instead.
    if call_active; then echo "A call is in progress. The new build is staged; quit and reopen Phone Assistant after the call." >&2; exit 0; fi
    /usr/bin/osascript -e 'quit app id "com.codexcall.menu"' >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -qxf "$EXECUTABLE" || break; sleep 0.2; done
    if pgrep -qxf "$EXECUTABLE"; then echo "Phone Assistant is still running; quit it and try again." >&2; exit 1; fi
  fi
  /usr/bin/open "$APP"
}
case "$MODE" in
  run) launch ;;
  --debug) lldb -- "$EXECUTABLE" ;;
  --verify) launch; sleep 1; pgrep -qxf "$EXECUTABLE" ;;
  --logs|--telemetry) launch; /usr/bin/log stream --info --style compact --predicate 'process == "CallMenu"' ;;
  --build-only) ;;
  *) echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2;exit 2 ;;
esac
