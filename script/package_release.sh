#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PHONE_KIT_RELEASE=1
: "${PHONE_KIT_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${PHONE_KIT_BUILD_VERSION:?Set a monotonically increasing helper version, for example 3.1.0}"
"$ROOT/script/build_and_run.sh" --build-only
APP="$ROOT/dist/CallMenu.app"
/usr/bin/codesign --verify --strict --deep "$APP"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}chatgpt-phone-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
RELEASE_APP="$STAGING/Phone Assistant.app"
/usr/bin/ditto "$APP" "$RELEASE_APP"
/usr/bin/codesign --verify --strict --deep "$RELEASE_APP"
/usr/bin/ditto -c -k --keepParent "$RELEASE_APP" "$ROOT/dist/Phone-Assistant.zip"
echo "Signed archive created. It is not notarized yet."
if [[ "${1:-}" == "--notarize" ]]; then
    : "${PHONE_KIT_NOTARY_PROFILE:?Set the name of your existing notarytool keychain profile}"
    xcrun notarytool submit "$ROOT/dist/Phone-Assistant.zip" --keychain-profile "$PHONE_KIT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$RELEASE_APP"
    xcrun stapler validate "$RELEASE_APP"
    spctl --assess --type execute --verbose=2 "$RELEASE_APP"
    /usr/bin/ditto -c -k --keepParent "$RELEASE_APP" "$ROOT/dist/Phone-Assistant.zip"
fi
