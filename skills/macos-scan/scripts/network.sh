#!/bin/bash
# network.sh - listeners, outbound connections, DNS, hosts, proxies, VPNs, trusted certificates.
# Usage: network.sh
# Read-only, no sudo, no name lookups (lsof -n, no reverse DNS).
# Rows: section|process|pid|detail|note
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

echo "section|process|pid|detail|note"
# Without root, lsof shows only sockets owned by this user: sshd on :22, screen sharing and
# other root daemons are missing. The root block in SKILL.md has the full listing.
[ "$(id -u)" = 0 ] || echo "scope|||user-owned sockets only|run: sudo lsof -nP -iTCP -sTCP:LISTEN for root-owned listeners"

# lsof -F: p=pid, c=command, n=name. +c 0 keeps full command names.
lsof_rows() {
  lsof -nP +c 0 "$@" -Fpcn 2>/dev/null | awk '
    /^p/ {pid=substr($0,2)} /^c/ {cmd=substr($0,2)} /^n/ {print cmd"|"pid"|"substr($0,2)}'
}

lsof_rows -iTCP -sTCP:LISTEN | sort -u | while IFS='|' read -r cmd pid addr; do
  scope=loopback
  case "$addr" in 127.*|"[::1]"*|localhost*) ;; *) scope=all-interfaces ;; esac
  exe=$(ps -o comm= -p "$pid" 2>/dev/null)
  printf 'listen-tcp|%s|%s|%s|%s %s\n' "$cmd" "$pid" "$addr" "$scope" "$exe"
done

lsof_rows -iUDP | sort -u | while IFS='|' read -r cmd pid addr; do
  case "$addr" in *"->"*) continue ;; esac
  case "$addr" in 127.*|"[::1]"*) scope=loopback ;; *) scope=all-interfaces ;; esac
  printf 'listen-udp|%s|%s|%s|%s\n' "$cmd" "$pid" "$addr" "$scope"
done

# Established outbound, grouped by process and remote address.
lsof_rows -iTCP -sTCP:ESTABLISHED | awk -F'|' '{split($3, a, "->"); print $1"|"$2"|"a[2]}' |
  grep -vE '\|(127\.|\[::1\])' | sort | uniq -c | sort -rn |
  awk '{c=$1; $1=""; sub(/^ /,""); print "established|"$0"|"c" connection(s)"}' | awk -F'|' -v OFS='|' '{print $1,$2,$3,$4,$5}'

scutil --dns 2>/dev/null | awk '/nameserver\[/ {print $3}' | sort -u | while read -r ns; do
  printf 'dns|||%s|resolver\n' "$ns"
done
for f in /etc/resolver/*; do
  [ -e "$f" ] && printf 'dns-resolver-file|||%s|modified %s\n' "$f" "$(mtime "$f")"
done

# /etc/hosts lines beyond the stock localhost entries.
grep -vE '^\s*(#|$)' /etc/hosts 2>/dev/null |
  grep -vE '^\s*(127\.0\.0\.1|255\.255\.255\.255|::1|fe80::1%lo0)\s+(localhost|broadcasthost)\s*$' |
  while read -r line; do printf 'hosts|||%s|\n' "$line"; done

scutil --proxy 2>/dev/null | awk '/Enable : 1|ProxyAutoConfigURLString|HTTPProxy |HTTPSProxy |SOCKSProxy / {gsub(/^ +/,""); print "proxy|||"$0"|"}'

scutil --nc list 2>/dev/null | awk 'NR>1 && NF {print "vpn|||"$0"|"}'

# Certificates the user or an admin chose to trust. Names only.
for dom in "" "-d"; do
  label="user"; [ "$dom" = "-d" ] && label="admin"
  security dump-trust-settings $dom 2>/dev/null | sed -n 's/^Cert [0-9]*: //p' | while read -r name; do
    printf 'trusted-cert|%s||%s|custom trust setting\n' "$label" "$name"
  done
done
security find-certificate -a /Library/Keychains/System.keychain 2>/dev/null |
  sed -n 's/.*"labl"<blob>="\(.*\)"/\1/p' | sort -u | while read -r name; do
    printf 'system-keychain-cert|||%s|\n' "$name"
  done

if [ -x "/Applications/Little Snitch.app/Contents/Components/littlesnitch" ]; then
  echo "little-snitch|||installed|rules and traffic log need root: see phases/network.md"
fi
exit 0
