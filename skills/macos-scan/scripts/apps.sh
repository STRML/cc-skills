#!/bin/bash
# apps.sh - every app bundle with signer, Gatekeeper verdict, last use, size and quarantine.
# Usage: apps.sh [extra-dir ...]
# Scans /Applications and ~/Applications one folder deep, plus any directories given.
# Read-only, no sudo. Slow on large app folders (du on each bundle): allow ~5 minutes.
# Rows: kb|path|bundle_id|version|signer|team|gatekeeper|last_used|date_added|app_store|quarantine
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

echo "kb|path|bundle_id|version|signer|team|gatekeeper|last_used|date_added|app_store|quarantine"
for root in /Applications "$HOME/Applications" "$@"; do
  for a in "$root"/*.app "$root"/*/*.app; do
    [ -d "$a" ] || continue
    case "$a" in /Applications/Utilities/*) continue ;; esac
    info="$a/Contents/Info.plist"
    bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null)
    ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info" 2>/dev/null)
    lu=$(mdls -raw -name kMDItemLastUsedDate "$a" 2>/dev/null | cut -c1-10)
    ad=$(mdls -raw -name kMDItemDateAdded "$a" 2>/dev/null | cut -c1-10)
    kb=$(du -sk "$a" 2>/dev/null | cut -f1)
    mas=no; [ -d "$a/Contents/_MASReceipt" ] && mas=yes
    q=no; xattr -p com.apple.quarantine "$a" >/dev/null 2>&1 && q=yes
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "${kb:-0}" "$a" "$bid" "$ver" "$(sig "$a")" "$lu" "$ad" "$mas" "$q"
  done
done
