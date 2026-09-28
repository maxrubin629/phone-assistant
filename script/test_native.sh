#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_OUTPUT="$ROOT/artifacts/native-checks"
mkdir -p "$TEST_OUTPUT/clang-cache" "$TEST_OUTPUT/swift-cache"
export CLANG_MODULE_CACHE_PATH="$TEST_OUTPUT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TEST_OUTPUT/swift-cache"
swift test --arch arm64 --package-path "$ROOT/native" --disable-sandbox
sh "$ROOT/native/Tests/CallAudioDSPChecks/run.sh"
python3 "$ROOT/script/test_native_transport.py"
