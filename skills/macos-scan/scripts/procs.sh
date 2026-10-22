#!/bin/bash
# procs.sh - running processes whose executable is not part of macOS, with signatures.
# Usage: procs.sh
# Read-only, no sudo. Signs each unique executable once, so it stays fast.
# Rows: signer|team|gatekeeper|pids|max_cpu|user|path|flags
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

TMP=$(mktemp -d -t macos-scan-procs)
trap 'rm -rf "$TMP"' EXIT

# pid|cpu|user|path. Paths may contain spaces, so read pid first and ask for comm alone.
ps -axo pid=,%cpu=,user= | while read -r pid cpu user; do
  exe=$(ps -o comm= -p "$pid" 2>/dev/null)
  # comm is argv[0]: relative for login shells, rewritten by some daemons
  # (redis puts its address there). Ask lsof for the mapped executable instead.
  case "$exe" in
    /*) [ -e "$exe" ] || exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) ;;
    *) exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) ;;
  esac
  [ -n "$exe" ] || continue
  case "$exe" in
    /System/*|/usr/libexec/*|/usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*|/Library/Apple/*|/private/var/db/*|/usr/lib/*) continue ;;
    */CoreSimulator/Volumes/*/RuntimeRoot/*|*/CoreSimulator/Profiles/Runtimes/*) continue ;;   # Apple-signed simulator OS
  esac
  printf '%s|%s|%s|%s\n' "$pid" "$cpu" "$user" "$exe"
done > "$TMP/procs"

echo "signer|team|gatekeeper|pids|max_cpu|user|path|flags"
cut -d'|' -f4- "$TMP/procs" | sort -u | while IFS= read -r exe; do
  s=$(sig "$exe")
  is_apple "${s%%|*}" && continue   # App Store apps stay listed: they are third-party code
  rows=$(awk -F'|' -v e="$exe" '{path=$4; for (i = 5; i <= NF; i++) path = path "|" $i} path == e' "$TMP/procs")
  pids=$(printf '%s\n' "$rows" | cut -d'|' -f1 | tr '\n' ' ')
  cpu=$(printf '%s\n' "$rows" | cut -d'|' -f2 | sort -rn | head -1)
  usr=$(printf '%s\n' "$rows" | cut -d'|' -f3 | sort -u | tr '\n' ' ')
  f=$(risky_path "$exe")
  if [ ! -e "$exe" ]; then f="$f binary-deleted"
  elif [ ! -x "$exe" ]; then f="$f name-is-not-an-executable"; fi
  awk -v c="${cpu:-0}" 'BEGIN{exit !(c>=50)}' && f="$f high-cpu"
  printf '%s|%s|%s|%s|%s|%s\n' "$s" "${pids% }" "${cpu:-0}" "${usr% }" "$exe" "${f# }"
done
