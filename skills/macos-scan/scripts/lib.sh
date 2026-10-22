#!/bin/bash
# Shared helpers for the macos-scan collectors. Source this file; do not run it.
# Everything here is read-only.
#
# Remote use: `cat lib.sh posture.sh | ssh <host> 'bash -s'` runs a collector on another
# Mac without copying files; the guard below tells the collector the helpers are loaded.
# shellcheck disable=SC2034  # read by the collectors after this file is concatenated in front
MACOS_SCAN_LIB=1

# System tools first: the scripts rely on BSD flags (stat -f, sed -E), and a scan for
# malware must not run a look-alike `codesign` or `find` from a user-writable folder.
# Homebrew and per-user tool folders come last, to fill gaps (brew, go, uv, timeout).
# Over `ssh host 'bash -s'` PATH is minimal, so they are added explicitly.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin"
export PATH
# Any brew call may otherwise update tap metadata first, which is a write.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1

# Stock macOS has no `timeout`. Without one every timed find or du would fail and look
# like "nothing found", so fall back to perl's alarm (exit status 142 on expiry).
if ! command -v timeout >/dev/null 2>&1; then
  timeout() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }
fi
# timed_out STATUS -> true when a timeout ended the command (GNU 124, perl alarm 142)
timed_out() { [ "$1" = 124 ] || [ "$1" = 142 ]; }
# timeout_row STATUS WHAT -> a "skipped|WHAT|timed out|" row (kind|path|detail|modified)
# when a timed command ran out of time. Call it with ${PIPESTATUS[0]} right after the pipe.
timeout_row() { timed_out "$1" && printf 'skipped|%s|timed out after %ss|\n' "$2" "${T:-?}"; return 0; }

# usage_if_help ARGS -> print the calling script's header comment and exit on -h/--help
usage_if_help() {
  case "${1:-}" in
    -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
  esac
}

# sig PATH -> "signer|team|gatekeeper"
#   signer: Authority leaf, ADHOC, UNSIGNED, or MISSING
#   gatekeeper: spctl verdict and source, e.g. "accepted:Notarized Developer ID"
# Plain `codesign -dv` hides the Authority chain, so this uses -dvv.
sig() {
  local b="$1" o a t
  if [ ! -e "$b" ]; then echo "MISSING||"; return; fi
  o=$(codesign -dvv "$b" 2>&1)
  case "$o" in
    *"not signed at all"*|*"code object is not signed"*) echo "UNSIGNED||"; return ;;
  esac
  t=$(printf '%s\n' "$o" | sed -n 's/^TeamIdentifier=//p' | head -1)
  [ "$t" = "not set" ] && t=""
  if printf '%s\n' "$o" | grep -q '^Signature=adhoc'; then
    a="ADHOC"
  else
    a=$(printf '%s\n' "$o" | sed -n 's/^Authority=//p' | head -1)
  fi
  gk "$b"
  echo "${a:-?}|${t}|${GK}"
}

# is_apple SIGNER -> true only for Apple's own code signing identities. App Store apps
# ("Apple Mac OS Application Signing") and "Apple Development: <anyone>" are not Apple's code.
is_apple() {
  case "$1" in "Software Signing"|"macOS Software Signing") return 0 ;; esac
  return 1
}

# gk PATH -> sets GK to "accepted:<source>" or "rejected:<source>".
# Bare Mach-O helpers are "rejected" by the exec assessment even when notarized,
# so the install assessment supplies the source for them.
gk() {
  local o v s
  o=$(spctl -a -vv -t exec "$1" 2>&1)
  v=$(printf '%s\n' "$o" | head -1 | grep -oE 'accepted|rejected' | head -1)
  s=$(printf '%s\n' "$o" | sed -n 's/^source=//p' | head -1)
  if [ -z "$s" ]; then
    s=$(spctl -a -vv -t install "$1" 2>&1 | sed -n 's/^source=//p' | head -1)
  fi
  GK="${v:-?}:${s:-none}"
}

# mtime PATH -> YYYY-MM-DD
mtime() { stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null; }

# age_days PATH -> whole days since last modification
age_days() {
  local m
  m=$(stat -f '%m' "$1" 2>/dev/null) || { echo ""; return; }
  echo $(( ( $(date +%s) - m ) / 86400 ))
}

# risky_path PATH -> prints a flag when the path sits somewhere malware likes
risky_path() {
  case "$1" in
    /tmp/*|/private/tmp/*|/private/var/tmp/*|/var/tmp/*) echo "tmp-path" ;;
    /private/var/folders/*) echo "temp-folder-path" ;;
    /Users/Shared/*) echo "users-shared-path" ;;
    */Downloads/*) echo "downloads-path" ;;
    */.Trash/*) echo "trash-path" ;;
    */.*) echo "hidden-path" ;;
  esac
}

# redact -> mask secrets in any text you are about to print or read: values after
# secret-looking flags (the flag name must end with the word, so --author survives),
# quoted values, -p<x> and -p <x>, Authorization and Bearer headers, user:password@ in
# URLs, and KEY=value environment assignments. selftest.sh checks the cases.
redact() {
  perl -pe '
    s{(--?(?:[a-z0-9]+[-_])*(?:api[-_]?)?(?:key|token|secret|pass|passwd|password|passphrase|bearer|auth|authorization|credentials?)(?:=|\s+))("[^"]*"|\x27[^\x27]*\x27|\S+)}{$1<redacted>}gi;
    s{(\bauthorization:\s*(?:bearer|basic|token)\s+)\S+}{$1<redacted>}gi;
    s{(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}}{$1<redacted>}gi;
    s{(\b[a-z][a-z0-9+.-]*://)[^/\s@]+@}{$1<redacted>@}gi;
    s{(\s-p)(?=\S)\S+}{$1<redacted>}g;
    s{(\s-p\s+)\S+}{$1<redacted>}g;
    s{\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|AUTH|CREDENTIALS?)[A-Z0-9_]*=)("[^"]*"|\x27[^\x27]*\x27|\S+)}{$1<redacted>}g;
  '
}

# have CMD -> true when CMD is on PATH
have() { command -v "$1" >/dev/null 2>&1; }

# have_git -> true when git can run without popping the Command Line Tools installer
# (/usr/bin/git is only a stub until the tools are installed).
have_git() {
  local g
  g=$(command -v git 2>/dev/null) || return 1
  [ "$g" != /usr/bin/git ] || xcode-select -p >/dev/null 2>&1
}

# py -> a python3 that will not trigger the Command Line Tools install prompt
py() {
  if [ -x /opt/homebrew/bin/python3 ]; then echo /opt/homebrew/bin/python3
  elif [ -x /usr/local/bin/python3 ]; then echo /usr/local/bin/python3
  elif xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then echo /usr/bin/python3
  fi
}

# home_children -> top-level entries of $HOME, minus Library and cloud mounts.
# Use this instead of walking $HOME directly: ~/Library/CloudStorage and
# iCloud Drive are network-backed and a recursive walk pins the machine.
# Entries on another device (container and VM mounts such as ~/OrbStack) are skipped too.
home_children() {
  local e dev
  dev=$(stat -f %d "$HOME")
  for e in "$HOME"/* "$HOME"/.[!.]*; do
    [ -e "$e" ] || continue
    case "$e" in
      "$HOME/Library"|"$HOME/.Trash") continue ;;
    esac
    [ -L "$e" ] && continue
    [ "$(stat -f %d "$e" 2>/dev/null)" = "$dev" ] || continue
    printf '%s\n' "$e"
  done
}
