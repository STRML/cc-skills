#!/bin/bash
# disk.sh - where the space went, by ALLOCATED size (what the disk actually holds).
# Usage: disk.sh known                 caches, model stores, toolchains, VM images, backups
#        disk.sh top                   biggest folders in ~ and ~/Library
#        disk.sh files [MIN_MB]        biggest files under ~ (default 500 MB)
#        disk.sh node_modules DIR...   node_modules trees under code folders
#        disk.sh snapshots             Time Machine local snapshots
#        disk.sh all
# Read-only, no sudo. Sizes come from du -k / stat %b, never the logical size: sparse VM
# disks report terabytes and cloud placeholders report files that are not on disk.
# ~/Library/CloudStorage, iCloud Drive and other mounted volumes are never walked.
# Rows: section|kb|path|modified|class   (class: regenerates, redownloadable, data, mixed)
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

T=${SCAN_TIMEOUT:-600}
# Timed-out walks are collected here and printed last, so sort and head cannot drop them.
SKIPS=$(mktemp -t macos-scan-disk)
trap 'rm -f "$SKIPS"' EXIT
skip() { printf 'skipped||%s||timed out after %ss\n' "$1" "$T" >> "$SKIPS"; }

kb() {
  local out
  out=$(timeout "$T" du -xsk "$1" 2>/dev/null)
  if timed_out "$?"; then echo TIMEOUT; else printf '%s' "$out" | cut -f1; fi
}
row() {
  local k; k=$(kb "$2")
  [ "$k" = TIMEOUT ] && { skip "$2"; return; }
  [ -n "$k" ] && [ "$k" -gt 0 ] && printf '%s|%s|%s|%s|%s\n' "$1" "$k" "$2" "$(mtime "$2")" "$3"
}

known() {
  local H="$HOME" L="$HOME/Library" bc=""
  have brew && bc=$(brew --cache 2>/dev/null)
  while IFS='|' read -r path class; do
    [ -n "$path" ] || continue
    [ -e "$path" ] && row known "$path" "$class"
  done <<EOF
$L/Caches|regenerates
$H/.cache/huggingface|redownloadable
$H/.cache/lm-studio|redownloadable
$H/.lmstudio/models|redownloadable
$H/.ollama/models|redownloadable
$H/.cache/uv|regenerates
$H/.cache/pip|regenerates
$H/.cache/go-build|regenerates
$H/.npm/_cacache|regenerates
$L/pnpm/store|regenerates
$H/.local/share/pnpm/store|regenerates
$H/.bun/install/cache|regenerates
$H/.cargo/registry|regenerates
$H/.rustup/toolchains|redownloadable
$H/go/pkg/mod|regenerates
$H/.gradle/caches|regenerates
$H/.m2/repository|regenerates
${bc:-/nonexistent}|regenerates
$L/Developer/Xcode/DerivedData|regenerates
$L/Developer/Xcode/iOS DeviceSupport|redownloadable
$L/Developer/Xcode/watchOS DeviceSupport|redownloadable
$L/Developer/Xcode/Archives|data
$L/Developer/CoreSimulator/Devices|mixed
$L/Developer/CoreSimulator/Caches|regenerates
$L/Containers/com.docker.docker/Data/vms|mixed
$H/.orbstack|mixed
$L/Group Containers/HUAQ24HBR6.dev.orbstack|mixed
$H/Parallels|data
$H/Virtual Machines.localized|data
$L/Containers/com.utmapp.UTM|data
$L/Application Support/MobileSync/Backup|data
$L/Messages/Attachments|data
$L/Mail|data
$H/.Trash|data
EOF
}

top() {
  home_children | while IFS= read -r e; do row top "$e" ""; done | sort -t'|' -k2,2rn | head -25
  for e in "$HOME/Library"/*; do
    case "$e" in */CloudStorage|*/Mobile\ Documents) continue ;; esac
    row library "$e" ""
  done | sort -t'|' -k2,2rn | head -15
  for d in "Application Support" Containers "Group Containers" Caches Developer; do
    for e in "$HOME/Library/$d"/*; do [ -e "$e" ] && row "library/$d" "$e" ""; done | sort -t'|' -k2,2rn | head -10
  done
}

files() {
  local min=${1:-500}
  { home_children
    for e in "$HOME/Library"/*; do
      case "$e" in */CloudStorage|*/Mobile\ Documents) ;; *) printf '%s\n' "$e" ;; esac
    done; } |
    while IFS= read -r d; do
      timeout "$T" find "$d" -xdev -type f -size +"${min}"M -print0 2>/dev/null |
        xargs -0 stat -f '%b|%z|%Sm|%N' -t '%Y-%m-%d' 2>/dev/null
      timed_out "${PIPESTATUS[0]}" && skip "$d"
    done | awk -F'|' -v min="$min" '{alloc=$1*512/1024; if (alloc >= min*1024) printf "file|%d|%s|%s|logical %d MB\n", alloc, $4, $3, $2/1048576}' |
    sort -t'|' -k2,2rn | head -40
}

node_modules() {
  for root in "$@"; do
    timeout "$T" find "$root" -xdev -type d -name node_modules -prune -print 2>/dev/null |
      while IFS= read -r d; do row node_modules "$d" regenerates; done
    timed_out "${PIPESTATUS[0]}" && skip "$root"
  done | sort -t'|' -k2,2rn | head -40
}

snapshots() {
  tmutil listlocalsnapshots / 2>/dev/null | awk 'NR>1 || !/^Snapshots/ {print "snapshot||"$0"||purgeable"}'
}

case "${1:-}" in
  known|top|files|node_modules|snapshots|all) echo "section|kb|path|modified|class" ;;
esac
case "${1:-}" in
  known) known ;;
  top) top ;;
  files) files "${2:-500}" ;;
  node_modules) shift; [ $# -gt 0 ] || { sed -n '2,8p' "$0"; exit 1; }; node_modules "$@" ;;
  snapshots) snapshots ;;
  all) known; top; files 500; snapshots ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
cat "$SKIPS"
