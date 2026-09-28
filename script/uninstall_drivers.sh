#!/usr/bin/env bash
set -euo pipefail
# Explicit reversible removal of Send only; never called during ordinary Stop.
[[ $# == 0 || ( $# == 1 && "$1" == --check ) ]] || { echo "Usage: $0 [--check]" >&2; exit 2; }
SOURCE=/Library/Audio/Plug-Ins/HAL/CodexCallSend.driver
[[ ! -L "$SOURCE" && ! -L /Library/Audio/Plug-Ins/HAL && ! -L /Library/Audio/Plug-Ins && ! -L /Library/Audio ]] || { echo "Refusing a symbolic-link path." >&2; exit 1; }
[[ -e "$SOURCE" ]] || { echo "Phone Assistant is not installed. No changes made."; exit 0; }
[[ -d "$SOURCE" && -z "$(/usr/bin/find "$SOURCE" -type l -print -quit)" ]] || { echo "Unexpected source bundle." >&2; exit 1; }
[[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" == com.codexcall.audio.send ]] || { echo "Unexpected bundle identity; nothing moved." >&2; exit 1; }
[[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleExecutable' "$SOURCE/Contents/Info.plist")" == CodexCallSend ]] || { echo "Unexpected executable; nothing moved." >&2; exit 1; }
/usr/bin/codesign --verify --strict "$SOURCE"
if [[ "${1:-}" == --check ]]; then echo "Installed Send identity verified. No changes made."; exit 0; fi
if [[ "$EUID" != 0 ]]; then echo "Administrator privileges are required." >&2; exit 1; fi
BACKUP_ROOT=/Library/Audio/CodexCallDisabled
[[ ! -L "$BACKUP_ROOT" ]] || { echo "Refusing a symbolic-link backup directory." >&2; exit 1; }
/bin/mkdir -p "$BACKUP_ROOT"
BACKUP=$(/usr/bin/mktemp -d "$BACKUP_ROOT/send.XXXXXX")
/bin/mv "$SOURCE" "$BACKUP/"
echo "Send bundle preserved in $BACKUP. Restart the Mac when convenient to unload it."
echo "No legacy Receive device, other driver, audio route, or audio service was changed."
