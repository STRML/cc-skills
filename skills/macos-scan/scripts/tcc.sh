#!/bin/bash
# tcc.sh - privacy permissions granted to apps and binaries, from both TCC databases.
# Usage: tcc.sh
# Read-only (sqlite3 -readonly), no sudo. The system database needs Full Disk Access
# for the terminal app; the user database is often still denied. Denied reads print a
# DENIED row instead of failing.
# Rows: db|service|client|auth|target|last_modified
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

echo "db|service|client|auth|target|last_modified"
# auth_value: 0 denied, 2 allowed, 3 limited. Only grants are listed.
Q="select replace(service,'kTCCService',''), client, case auth_value when 2 then 'allowed' when 3 then 'limited' else auth_value end, coalesce(indirect_object_identifier,''), datetime(last_modified,'unixepoch') from access where auth_value in (2,3) order by service, client;"
for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  label=system; case "$db" in "$HOME"*) label=user ;; esac
  if out=$(sqlite3 -readonly -separator '|' "$db" "$Q" 2>&1); then
    printf '%s\n' "$out" | awk -v d="$label" 'NF {print d"|"$0}'
  else
    printf '%s|DENIED|%s|||\n' "$label" "$(printf '%s' "$out" | head -1 | tr '|' '/')"
  fi
done
