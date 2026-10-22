#!/bin/bash
# unused.sh - rank apps nobody has opened in a while, biggest first.
# Usage: unused.sh APPS.tsv [PERSISTENCE.tsv] [PROCS.tsv] [DAYS]
#   APPS.tsv from apps.sh; the optional files mark apps that autostart or are running.
# Rows: status|kb|app|last_used|days_idle|autostart|running
#   status: unused (last use older than DAYS), no-usage-record (Spotlight has no date), recent
# A missing last-used date never counts as unused: Spotlight leaves it empty for apps
# launched from the command line, by a helper, or never indexed.
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"
[ -n "${1:-}" ] || { sed -n '2,8p' "$0"; exit 1; }
APPS="$1" PERSIST="${2:-/dev/null}" PROCS="${3:-/dev/null}" DAYS="${4:-90}"
now=$(date +%s)

echo "status|kb|app|last_used|days_idle|autostart|running"
# Warn when one "date added" covers most apps: an OS upgrade or migration reset it,
# so it says nothing about when each app arrived.
awk -F'|' 'NR>1 && $9 != "" && $9 != "(null)" {n++; c[$9]++} END {for (d in c) if (c[d] > n/2) print "warning|||"d"|"c[d]" of "n" apps share this date added (upgrade or migration reset)||"}' "$APPS"

awk -F'|' 'NR>1' "$APPS" | while IFS='|' read -r kb path _ _ _ _ _ lu _ _ _; do
  auto=no; grep -qF "$path" "$PERSIST" 2>/dev/null && auto=yes
  run=no; grep -qF "$path/Contents/" "$PROCS" 2>/dev/null && run=yes
  case "$lu" in
    ""|"(null)") status=no-usage-record; idle="" ;;
    *) t=$(date -j -f '%Y-%m-%d' "$lu" +%s 2>/dev/null || echo "$now")
       idle=$(( (now - t) / 86400 ))
       status=recent; [ "$idle" -gt "$DAYS" ] && status=unused ;;
  esac
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$kb" "$path" "$lu" "$idle" "$auto" "$run"
done | sort -t'|' -k1,1 -k2,2rn
