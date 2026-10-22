#!/bin/bash
# artifacts.sh - on-disk traces that persistence and app listings miss: known malware
# paths, SUID binaries, unquarantined downloads, apps hidden in data folders,
# lookalike system apps, Dock entries, Folder Actions, installer receipts, SSH keys,
# browsers started with remote-control flags, and recent download origins.
# Usage: artifacts.sh
# Read-only, no sudo. Prints names and paths, never file contents.
# Rows: kind|path|detail|modified
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

HERE=$(cd "$(dirname "$0")" && pwd)
T=${SCAN_TIMEOUT:-300}
echo "kind|path|detail|modified"

# 1. Known malware paths (existence only). A third field, when present, is a regex the
# file name must match (globs cannot say "digits only").
IOC_FILE=${IOC_FILE:-$HERE/ioc-paths.txt}
if [ -r "$IOC_FILE" ]; then
  checked=0
  while IFS='|' read -r family pattern name_re; do
    case "$family" in ''|\#*) continue ;; esac
    checked=$((checked + 1))
    pattern=${pattern/#\~/$HOME}
    # Split on newlines only, so paths with spaces survive while globs still expand.
    OLDIFS=$IFS; IFS='
'
    for p in $pattern; do
      [ -e "$p" ] || continue
      if [ -n "$name_re" ] && ! [[ "$(basename "$p")" =~ $name_re ]]; then continue; fi
      printf 'ioc-hit|%s|%s (verify before trusting)|%s\n' "$p" "$family" "$(mtime "$p")"
    done
    IFS=$OLDIFS
  done < "$IOC_FILE"
  echo "ioc-checked||$checked known paths|"
else
  echo "skipped|ioc-paths.txt|not found next to the script: set IOC_FILE|"
fi

# 2. SUID/SGID files outside the sealed system volume.
{ printf '%s\n' /usr/local /opt/homebrew /Applications; home_children; } | while IFS= read -r d; do
  [ -d "$d" ] || continue
  timeout "$T" find "$d" -xdev \( -name node_modules -o -name .git \) -prune -o -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null |
    while IFS= read -r f; do printf 'suid-sgid|%s|%s owner=%s|%s\n' "$f" "$(sig "$f" | cut -d'|' -f1)" "$(stat -f %Su "$f")" "$(mtime "$f")"; done
  timeout_row "${PIPESTATUS[0]}" "suid scan of $d"
done

# 3. Downloads: apps, installers and executables, with quarantine state.
if [ -d "$HOME/Downloads" ]; then
  timeout "$T" find "$HOME/Downloads" -maxdepth 3 \( -name '*.app' -type d -prune -print \) -o \
    \( -type f \( -name '*.pkg' -o -name '*.dmg' -o -name '*.command' -o -name '*.sh' -o -perm -0100 \) -print \) 2>/dev/null |
    while IFS= read -r f; do
      q=no; xattr -p com.apple.quarantine "$f" >/dev/null 2>&1 && q=yes
      printf 'download-exec|%s|quarantine=%s %s|%s\n' "$f" "$q" "$(sig "$f" | cut -d'|' -f1)" "$(mtime "$f")"
    done
  timeout_row "${PIPESTATUS[0]}" "$HOME/Downloads"
fi

# 4. Hidden entries in the home folder and in Application Support.
for e in "$HOME"/.[!.]* "$HOME/Library/Application Support"/.[!.]*; do
  [ -e "$e" ] || continue
  born=$(stat -f %B "$e" 2>/dev/null || echo 0)
  age=$(( ( $(date +%s) - born ) / 86400 ))
  # Plain dotfiles are config and history; report folders and executables only.
  kind=""
  if [ -f "$e" ] && [ -x "$e" ]; then kind="executable:$(file -b "$e" 2>/dev/null | cut -c1-40)"
  elif [ -d "$e" ] && [ "$age" -le 30 ]; then kind="folder"
  fi
  [ -n "$kind" ] && printf 'hidden-home|%s|%s created %sd ago|%s\n' "$e" "$kind" "$age" "$(mtime "$e")"
done

# 5. App bundles parked in data and temp folders.
for d in "$HOME/Library/Application Support" "$HOME/Library/Caches" /Library/Caches /private/tmp /private/var/tmp /Users/Shared; do
  [ -d "$d" ] || continue
  timeout "$T" find "$d" -maxdepth 4 -name '*.app' -type d -prune 2>/dev/null |
    while IFS= read -r a; do
      [ -f "$a/Contents/Info.plist" ] || continue   # a data folder named *.app, not a bundle
      printf 'app-in-data-dir|%s|%s|%s\n' "$a" "$(sig "$a" | cut -d'|' -f1)" "$(mtime "$a")"
    done
  timeout_row "${PIPESTATUS[0]}" "app scan of $d"
done

# 6. Hidden files inside app bundles, and lookalike system apps outside /System.
for f in /Applications/*.app/Contents/MacOS/.[!.]* "$HOME"/Applications/*.app/Contents/MacOS/.[!.]*; do
  [ -e "$f" ] && printf 'hidden-in-bundle|%s||%s\n' "$f" "$(mtime "$f")"
done
for n in Finder Terminal Reminders SimulatorTrampoline "System Settings" "System Preferences" Calendar Notes Mail Messages Xcode-helper; do
  for a in "/Applications/$n.app" "$HOME/Applications/$n.app"; do
    [ -d "$a" ] || continue
    s=$(sig "$a" | cut -d'|' -f1)
    is_apple "$s" && continue
    printf 'lookalike-app|%s|%s|%s\n' "$a" "$s" "$(mtime "$a")"
  done
done

# 7. Shared and temp folders: hidden entries and executables.
relocated=0
for d in /Users/Shared /private/var/tmp /private/tmp; do
  for e in "$d"/* "$d"/.[!.]*; do
    [ -e "$e" ] || continue
    case "$(basename "$e")" in
      .localized|.DS_Store|com.apple.*|.X11-unix|.font-unix|.ICE-unix) continue ;;
      "Previously Relocated Items"*) relocated=$((relocated + 1)); continue ;;  # left by macOS upgrades
    esac
    kind=""
    case "$(basename "$e")" in .*) kind=hidden ;; esac
    [ -f "$e" ] && file -b "$e" 2>/dev/null | grep -q 'Mach-O' && kind="${kind:+$kind,}mach-o"
    [ "$d" = /Users/Shared ] && [ -z "$kind" ] && kind=entry
    [ -n "$kind" ] && printf 'shared-tmp|%s|%s|%s\n' "$e" "$kind" "$(mtime "$e")"
  done
done
[ "$relocated" -gt 0 ] && echo "shared-tmp|/Users/Shared/Previously Relocated Items*|$relocated folders left by macOS upgrades|"

# 8. Dock items that point outside /Applications and /System.
defaults read com.apple.dock persistent-apps 2>/dev/null | sed -n 's/.*"_CFURLString" = "\(.*\)";/\1/p' |
  grep -vE '^file:///(System/)?Applications/|^file:///System/' | while read -r u; do printf 'dock-item|%s||\n' "$u"; done

# 9. Folder Actions, directory-service plugins, screen savers.
fa=$(defaults read com.apple.FolderActionsDispatcher folderActionsEnabled 2>/dev/null || echo unset)
echo "folder-actions-enabled||$fa|"
for d in "$HOME/Library/Scripts/Folder Action Scripts" "/Library/Scripts/Folder Action Scripts" \
         /Library/DirectoryServices/PlugIns "$HOME/Library/Screen Savers" "/Library/Screen Savers"; do
  for e in "$d"/*; do
    [ -e "$e" ] && printf 'plugin-dir|%s|%s|%s\n' "$e" "$(sig "$e" | cut -d'|' -f1)" "$(mtime "$e")"
  done
done

# 10. Installer receipts not from Apple (pkg-delivered malware leaves one).
pkgutil --pkgs 2>/dev/null | grep -v '^com\.apple\.' | while read -r id; do
  when=$(pkgutil --pkg-info "$id" 2>/dev/null | sed -n 's/^install-time: //p')
  printf 'pkg-receipt|%s||%s\n' "$id" "$( [ -n "$when" ] && date -r "$when" '+%Y-%m-%d' )"
done

# 11. SSH keys that can log in to this Mac (fingerprints only).
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>/dev/null | awk -v m="$(mtime "$HOME/.ssh/authorized_keys")" '{print "authorized-key|~/.ssh/authorized_keys|"$NF" "$2" "$3"|"m}'
fi

# 12. Browsers started with flags that hand control to another program.
ps -axo pid=,args= 2>/dev/null | grep -E -- '--(load-extension|remote-debugging-port|remote-debugging-pipe|headless)' | grep -v grep |
  while read -r pid rest; do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null)
    flags=$(printf '%s' "$rest" | grep -oE -- '--(load-extension|remote-debugging-port|remote-debugging-pipe|headless)' | sort -u | tr '\n' ' ')
    printf 'browser-remote-flags|%s|pid %s %s|\n' "$exe" "$pid" "$flags"
  done

# 13. Secrets passed as command-line flags: any local user can read them with ps.
# Prints the flag name only, never the value.
ps -axo pid=,args= 2>/dev/null | grep -iE -- '--?([a-z0-9]+[-_])*(api[-_]?key|key|token|secret|password|passwd|pass|bearer|auth|authorization|credentials?)[ =][^ -]' | grep -v grep |
  while read -r pid rest; do
    flags=$(printf '%s' "$rest" | grep -oiE -- '--?([a-z0-9]+[-_])*(api[-_]?key|key|token|secret|password|passwd|pass|bearer|auth|authorization|credentials?)[ =]' | tr -d ' =' | sort -u | tr '\n' ' ')
    printf 'secret-in-args|%s|pid %s flags: %s|\n' "$(ps -o comm= -p "$pid" 2>/dev/null)" "$pid" "$flags"
  done

# 14. Where recent downloads came from (hostnames only, last 30 days).
QDB="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
if [ -r "$QDB" ]; then
  # LSQuarantineTimeStamp counts seconds from 2001-01-01 (978307200 in Unix time).
  sqlite3 -readonly -separator '|' "$QDB" "select coalesce(LSQuarantineAgentName,'?'), coalesce(LSQuarantineDataURLString, LSQuarantineOriginURLString, ''), date(LSQuarantineTimeStamp + 978307200, 'unixepoch') from LSQuarantineEvent where LSQuarantineTimeStamp + 978307200 > strftime('%s','now') - 30*86400;" 2>/dev/null |
    awk -F'|' '{h=$2; sub(/^[a-z]+:\/\//, "", h); sub(/[\/?#].*$/, "", h); sub(/^.*@/, "", h); print $1"|"h"|"$3}' | sort | uniq -c |
    awk '{c=$1; $1=""; sub(/^ /,""); split($0, a, "|"); print "download-origin|"(a[2] == "" ? "(no URL recorded)" : a[2])"|"a[1]" x"c"|"a[3]}'
else
  echo "download-origin|$QDB|DENIED or missing|"
fi
exit 0
