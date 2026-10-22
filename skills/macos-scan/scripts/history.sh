#!/bin/bash
# history.sh - evidence of what already ran: shell history patterns, XProtect results,
# SSH logins, osascript privacy prompts, and how far back the logs reach.
# Usage: history.sh [--logs] [--days N]
#   --logs   also query the unified log (slow: 1 to 5 minutes)
#   --days   look-back window for log queries (default 30)
# Read-only, no sudo. Shell history is reported as file, line, time and pattern name.
# The command text itself is never printed (it can hold tokens).
# Rows: kind|source|where|when|detail
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"

LOGS=no DAYS=30
while [ $# -gt 0 ]; do
  case "$1" in
    --logs) LOGS=yes ;;
    --days) DAYS="${2:?--days needs a number of days}"; shift ;;
    -h|--help) usage_if_help --help ;;
  esac
  shift
done

echo "kind|source|where|when|detail"

# Pattern name|extended regex. Each matches a common lure or post-exploitation step.
PATTERNS='curl-pipe-shell|(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|fi|da)?sh
quarantine-strip|xattr[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*(-d[[:space:]]+com\.apple\.quarantine|-[rsvx]*c[rsvx]*([[:space:]]|$))
base64-pipe|base64[[:space:]]+(-d|-D|--decode)[^|]*\|
osascript-inline|osascript[[:space:]]+-e
hidden-answer-prompt|hidden answer
gatekeeper-off|spctl[[:space:]]+--(master|global)-disable
authorization-check|dscl[[:space:]].*-authonly
history-wipe|history[[:space:]]+-c|(^|[;&|[:space:]])rm[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*[^;&|[:space:]]*_history([[:space:]]|$|;)
tmp-exec|chmod[[:space:]]+\+x[[:space:]]+/(private/)?tmp/'

# Print "line|epoch" for every history entry matching a regex, per shell format.
# The regex goes through ENVIRON: awk -v would turn "\|" into a bare "|".
hist_hits() {
  local file="$1" fmt="$2"
  case "$fmt" in
    zsh)   RE="$3" awk '{ t=""; if (match($0, /^: [0-9]+:/)) t=substr($0, 3, RLENGTH-3); if ($0 ~ ENVIRON["RE"]) print NR"|"t }' "$file" 2>/dev/null ;;
    fish)  RE="$3" awk '/^- cmd: / { hit=($0 ~ ENVIRON["RE"]); ln=NR; next } /^  when: / && hit { print ln"|"$2; hit=0 }' "$file" 2>/dev/null ;;
    bash)  RE="$3" awk '/^#[0-9]+$/ { t=substr($0,2); next } $0 ~ ENVIRON["RE"] { print NR"|"t; t="" }' "$file" 2>/dev/null ;;
  esac
}

scan_history() {
  local file="$1" fmt="$2" name re n
  if [ ! -e "$file" ]; then return; fi
  n=$(wc -l < "$file" | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    printf 'history-empty|%s|%s||empty file: a wiped history is not a clean one\n' "$fmt" "$file"
    return
  fi
  printf 'history-file|%s|%s|%s|%s lines\n' "$fmt" "$file" "$(mtime "$file")" "$n"
  printf '%s\n' "$PATTERNS" | while IFS='|' read -r name re; do
    hist_hits "$file" "$fmt" "$re" | while IFS='|' read -r line t; do
      when=""; [ -n "$t" ] && when=$(date -r "$t" '+%Y-%m-%d %H:%M' 2>/dev/null)
      printf 'history-hit|%s|%s:%s|%s|%s\n' "$fmt" "$file" "$line" "$when" "$name"
    done
  done
}

scan_history "$HOME/.zsh_history" zsh
scan_history "$HOME/.zhistory" zsh
for f in "$HOME"/.zsh_sessions/*.history; do [ -e "$f" ] && scan_history "$f" zsh; done
scan_history "$HOME/.bash_history" bash
scan_history "$HOME/.local/share/fish/fish_history" fish
login_shell=$(dscl . read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}')
echo "login-shell|dscl|${login_shell:-unknown (directory services blocked)}||"

# Login records do not depend on unified log retention.
last -n 30 2>/dev/null | awk 'NF && $1 != "wtmp" && $1 != "reboot" && $1 != "shutdown" {print "login-record|last|"$1" "$2"|"$3" "$4" "$5" "$6"|"$NF}' | sort -u

if [ "$LOGS" = yes ]; then
  # Full log records rarely go back 30 days. Report how far they actually reach.
  oldest=$(ls -tr /private/var/db/diagnostics/Persist/*.tracev3 2>/dev/null | head -1)
  echo "log-retention|Persist|${oldest:-unreadable}|$( [ -n "$oldest" ] && stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$oldest" )|oldest persistent log file; earlier events are gone"

  # LS NAME PREDICATE -> matching log lines. A timeout prints a skipped row straight to the
  # real stdout (fd 3), so the caller's sed pipeline cannot swallow it.
  exec 3>&1
  LS() {
    local out rc
    out=$(timeout 300 log show --last "${DAYS}d" --style compact --predicate "$2" 2>/dev/null); rc=$?
    if timed_out "$rc"; then echo "skipped|log|$1|timed out after 300s|" >&3; return; fi
    printf '%s\n' "$out" | grep -v '^Timestamp'
  }

  xp=$(LS xprotect 'subsystem == "com.apple.XProtectFramework" AND eventMessage CONTAINS "Status:"')
  printf '%s\n' "$xp" |
    grep -v NoThreatDetected | sed -n 's/^\([0-9-]* [0-9:]*\).*Scanner \[\([^]]*\)\] - Status: \(.*\)$/\1|\2|\3/p' |
    awk -F'|' '{print "xprotect|remediator|"$2"|"$1"|"$3}'
  echo "xprotect-runs|remediator||$(printf '%s\n' "$xp" | grep -c NoThreatDetected) clean results|"

  LS ssh 'process == "sshd" AND eventMessage CONTAINS "Accepted"' |
    sed -n 's/^\([0-9-]* [0-9:]*\).*Accepted \([a-z-]*\) for \([^ ]*\) from \([^ ]*\).*/\1|\2|\3|\4/p' |
    awk -F'|' '{print "ssh-login|sshd|"$3" from "$4"|"$1"|"$2}'

  LS tcc 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "osascript"' |
    sed -n 's/^\([0-9-]* [0-9:]*\).*\(kTCCService[A-Za-z]*\).*/\1|\2/p' | sort -u |
    awk -F'|' '{print "tcc-osascript|TCC|"$2"|"$1"|osascript asked for this permission"}'
fi
exit 0
