#!/bin/bash
# persistence.sh - everything that starts on its own, with code signatures.
# Usage: persistence.sh
# Read-only, no sudo. Prints pipe-delimited rows; the first column is the kind.
# Run outside the Claude Code sandbox so launchctl and codesign can see system items.
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

UIDN=$(id -u)
LABELS=$(mktemp -t macos-scan-labels)
trap 'rm -f "$LABELS"' EXIT

echo "kind|scope|item|label|modified|loaded|program|signer|team|gatekeeper|flags"

plist_flags() {
  # $1 plist, $2 program, $3 args, $4 label, $5 signer, $6 script run by an interpreter
  local f="" p="$1" prog="$2" args="$3" label="$4" signer="$5" script="${6:-}" rp
  [ -r "$p" ] || f="$f unreadable"
  [ -z "$label" ] && [ "$(stat -f %z "$p" 2>/dev/null || echo 0)" -lt 400 ] && f="$f stub-plist"
  [ -n "$prog" ] && [ ! -e "$prog" ] && f="$f missing-binary"
  case "$(basename "${prog:-x}")" in
    sh|bash|zsh|fish|dash|python*|perl|ruby|node|osascript|env) f="$f interpreter" ;;
  esac
  printf ' %s' "$args" | grep -qE '[[:space:]/](curl|wget|nc|eval)[[:space:]]|base64|osascript|python[0-9.]* -c|/dev/tcp' && f="$f risky-args"
  rp=$(risky_path "$prog"); [ -n "$rp" ] && f="$f $rp"
  if [ -n "$script" ]; then
    [ -e "$script" ] || f="$f missing-script"
    rp=$(risky_path "$script"); [ -n "$rp" ] && f="$f script-$rp"
  fi
  case "$label" in
    com.apple.*)
      # Apple's own jobs live in /System. Here, an Apple name must at least run Apple code,
      # and not a script handed to an Apple-signed interpreter.
      if [ -n "$signer" ] && ! is_apple "$signer"; then f="$f apple-name-not-apple-signed"
      elif [ -n "$script" ]; then f="$f apple-name-runs-script"; fi ;;
    *.service|*.system|launched.*) f="$f adload-style-label" ;;
    actions.runner.*) f="$f self-hosted-runner" ;;
  esac
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$p" 2>/dev/null | grep -q 'DYLD_' && f="$f dyld-env"
  [ "$(age_days "$p")" -le 30 ] 2>/dev/null && f="$f recent"
  printf '%s' "${f# }"
}

scan_dir() {
  local scope="$1" dir="$2" p label prog args s loaded domain
  for p in "$dir"/*.plist; do
    [ -e "$p" ] || continue
    label="" prog="" args="" script=""
    if [ -r "$p" ]; then
      label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null)
      prog=$(/usr/libexec/PlistBuddy -c 'Print :Program' "$p" 2>/dev/null)
      [ -n "$prog" ] || prog=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$p" 2>/dev/null)
      args=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$p" 2>/dev/null | sed '1d;$d;s/^ *//' | tr '\n' ' ')
      # For "bash /path/script" jobs, the script is what matters.
      case "$(basename "${prog:-x}")" in
        sh|bash|zsh|fish|dash|python*|perl|ruby|node|bun|deno|osascript)
          script=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$p" 2>/dev/null | sed '1,2d;$d;s/^ *//' | grep -m1 '^/') ;;
      esac
    fi
    if [ -n "$prog" ]; then s=$(sig "$prog"); else s="||"; fi
    case "$scope" in system-daemon) domain="system" ;; *) domain="gui/$UIDN" ;; esac
    loaded=no
    [ -n "$label" ] && launchctl print "$domain/$label" >/dev/null 2>&1 && loaded=yes
    [ -n "$label" ] && echo "$label" >> "$LABELS"
    printf 'launchd|%s|%s|%s|%s|%s|%s|%s|%s\n' "$scope" "$p" "${label:-<none>}" "$(mtime "$p")" "$loaded" "$prog${script:+ $script}" "$s" \
      "$(plist_flags "$p" "$prog" "$args" "$label" "${s%%|*}" "$script")"
  done
}

scan_dir system-daemon /Library/LaunchDaemons
scan_dir system-agent /Library/LaunchAgents
scan_dir user-agent "$HOME/Library/LaunchAgents"

# Jobs loaded in the user's launchd domain with no plist on disk. Apps that
# register helpers through SMAppService and "application.*" jobs are normal here.
# An empty list means launchctl was blocked, not that nothing is loaded.
jobs=$(launchctl list 2>/dev/null)
if [ "$(printf '%s\n' "$jobs" | wc -l)" -le 1 ]; then
  echo "launchd-no-plist|user|||||||||DENIED: launchctl list returned nothing (sandbox?)"
else
  printf '%s\n' "$jobs" | awk 'NR>1 {print $3}' | grep -vE '^(com\.apple\.|application\.|0x)' | sort -u |
    while read -r l; do
      grep -qxF "$l" "$LABELS" && continue
      printf 'launchd-no-plist|user||%s||yes|||||registered by an app or loaded by hand\n' "$l"
    done
fi

for b in /Library/PrivilegedHelperTools/*; do
  [ -e "$b" ] || continue
  printf 'helper-tool|system|%s||%s|||%s|%s\n' "$b" "$(mtime "$b")" "$(sig "$b")" "$(risky_path "$b")"
done

for b in /Library/StartupItems/* /Library/Security/SecurityAgentPlugins/*.bundle /Library/Extensions/*.kext; do
  [ -e "$b" ] || continue
  kind=startup-item
  case "$b" in *SecurityAgentPlugins*) kind=auth-plugin ;; *.kext) kind=kext-installed ;; esac
  printf '%s|system|%s||%s|||%s|\n' "$kind" "$b" "$(mtime "$b")" "$(sig "$b")"
done

# The bundle id is the field just before "(version)"; the last field is the dependency list.
if out=$(kmutil showloaded --list-only 2>&1); then
  printf '%s\n' "$out" | grep -v 'com\.apple\.' |
    awk 'NF { for (i = 1; i < NF; i++) if ($(i+1) ~ /^\(/) { print "kext-loaded|system|"$i"||||||||"; break } }'
else
  echo "kext-loaded|system|||||||||DENIED: kmutil failed"
fi

if out=$(systemextensionsctl list 2>&1); then
  printf '%s\n' "$out" | awk -F'\t' '/^\*|^\t/ && NF>=5 {print "system-extension|system|"$4"|"$5"||"$6"|||"$3"||"}'
else
  echo "system-extension|system|||||||||DENIED: systemextensionsctl failed"
fi

# App extensions (Finder sync, Safari, QuickLook, widgets) outside Apple.
if out=$(pluginkit -mAv 2>&1) && [ -n "$out" ]; then
  printf '%s\n' "$out" | grep -v 'com\.apple\.' | awk -F'\t' 'NF>=4 {
    id=$1; gsub(/^[ +\-!=]+/, "", id); print "app-extension|user|"$NF"|"id"||"(($1 ~ /^ *-/) ? "disabled" : "enabled")"|||||"}'
else
  echo "app-extension|user|||||||||DENIED: pluginkit returned nothing"
fi

# Cron and at. Only the program path of each cron line is printed.
crontab -l 2>/dev/null | grep -vE '^\s*(#|$)' | awk '{ if ($1 ~ /^@/) print $2; else print $6 }' |
  while read -r c; do printf 'cron|user|%s||||%s|%s|\n' "$c" "$c" "$(sig "$c")"; done
ls /usr/lib/cron/tabs >/dev/null 2>&1 || echo "cron|system|/usr/lib/cron/tabs||||||||DENIED (root only)"
atq 2>/dev/null | awk '{print "at|user|job "$1"||||||||"}'
for d in /etc/periodic/daily /etc/periodic/weekly /etc/periodic/monthly /usr/local/etc/periodic; do
  for f in "$d"/*; do
    [ -e "$f" ] && printf 'periodic|system|%s||%s||||||owner %s\n' "$f" "$(mtime "$f")" "$(stat -f '%Su' "$f")"
  done
done

for v in DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH; do
  val=$(launchctl getenv "$v" 2>/dev/null)
  [ -n "$val" ] && printf 'launchd-env|user|%s||||||||set\n' "$v"
done

# Shell startup files: name, date and which risky patterns they contain (no contents).
for f in "$HOME"/.zshenv "$HOME"/.zprofile "$HOME"/.zshrc "$HOME"/.zlogin "$HOME"/.zlogout \
         "$HOME"/.bash_profile "$HOME"/.bashrc "$HOME"/.profile "$HOME"/.config/fish/config.fish \
         "$HOME"/.config/fish/conf.d/*.fish /etc/zshrc /etc/zprofile /etc/zshenv /etc/profile /etc/bashrc \
         /etc/paths.d/*; do
  [ -e "$f" ] || continue
  hits=$(grep -nE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|fi)?sh|base64[[:space:]]+(-d|-D|--decode)|DYLD_|osascript|(^|[^[:alnum:]_])nc[[:space:]]+-e|/dev/tcp/|sysnotif-repair' "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ',' )
  scope=user
  case "$f" in /etc/*) scope=system ;; esac
  printf 'shell-startup|%s|%s||%s||||||%s\n' "$scope" "$f" "$(mtime "$f")" "${hits:+pattern-lines:${hits%,}}"
done
