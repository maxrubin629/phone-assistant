#!/usr/bin/env bash
# Builds dist/Phone-Assistant.dmg: the Developer ID-signed app beside an
# Applications shortcut. With --notarize, Apple notarizes the disk image and
# the ticket is stapled to it, so Gatekeeper accepts it on other Macs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PHONE_KIT_RELEASE=1
# Use the one installed Developer ID Application identity unless one is named.
if [[ -z "${PHONE_KIT_SIGNING_IDENTITY:-}" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')"
    if [[ "$(printf '%s\n' "$IDENTITIES" | grep -c .)" != 1 ]]; then
        echo "Set PHONE_KIT_SIGNING_IDENTITY to one installed Developer ID Application identity." >&2; exit 1
    fi
    export PHONE_KIT_SIGNING_IDENTITY="$IDENTITIES"
fi
: "${PHONE_KIT_BUILD_VERSION:?Set a monotonically increasing helper version, for example 3.3.0}"
"$ROOT/script/build_and_run.sh" --build-only
APP="$ROOT/dist/CallMenu.app"
/usr/bin/codesign --verify --strict --deep "$APP"

STAGING="$(mktemp -d "${TMPDIR:-/tmp/}phone-assistant-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/Phone Assistant"
RELEASE_APP="$STAGING/Phone Assistant/Phone Assistant.app"
/usr/bin/ditto "$APP" "$RELEASE_APP"
/usr/bin/codesign --verify --strict --deep "$RELEASE_APP"
ln -s /Applications "$STAGING/Phone Assistant/Applications"

DMG="$ROOT/dist/Phone-Assistant.dmg"
rm -f "$DMG"
hdiutil create -volname "Phone Assistant" -srcfolder "$STAGING/Phone Assistant" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
/usr/bin/codesign --sign "$PHONE_KIT_SIGNING_IDENTITY" --timestamp "$DMG"
/usr/bin/codesign --verify --strict "$DMG"
echo "Signed disk image created at $DMG. It is not notarized yet."

if [[ "${1:-}" == "--notarize" ]]; then
    : "${PHONE_KIT_NOTARY_PROFILE:?Set the name of your notarytool keychain profile}"
    xcrun notarytool submit "$DMG" --keychain-profile "$PHONE_KIT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    echo "Notarized and stapled: $DMG"
fi
