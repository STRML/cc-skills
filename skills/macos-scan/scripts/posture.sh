#!/bin/bash
# posture.sh - security settings of this Mac, one "check|value" row each.
# Usage: posture.sh
# Read-only, no sudo. Under the Claude Code sandbox, dscl, fdesetup and
# sharing fail with eServerError: run this script with the sandbox bypass.
# A blocked query prints "DENIED: <reason>" instead of an empty or default value.
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

row() { printf '%s|%s\n' "$1" "$2"; }
first() { "$@" 2>&1 | head -1; }

# probe CMD... -> the command's output, or "DENIED: <first line>" (status 1) when it
# failed or was blocked. These tools often exit 0 while printing a refusal.
probe() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  case "$out" in
    *eServerError*|*"Operation not permitted"*|*"Unable to"*|*"cannot be found in local DS"*|*"Unknown volume"*) rc=1 ;;
  esac
  if [ "$rc" -ne 0 ]; then printf 'DENIED: %s' "$(printf '%s\n' "$out" | head -1)"; return 1; fi
  printf '%s' "$out"
}
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

echo "check|value"
row macos "$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
row sip "$(first csrutil status)"
row gatekeeper "$(first spctl --status)"
row filevault "$(probe fdesetup status | head -1)"
row firewall "$(first "$FW" --getglobalstate)"
row firewall-stealth "$(first "$FW" --getstealthmode)"
row firewall-block-all "$(first "$FW" --getblockall)"

if have xprotect; then
  row xprotect "$(xprotect version 2>&1 | tr '\n' ' ')"
else
  row xprotect "$(defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist CFBundleShortVersionString 2>&1)"
fi

for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do
  row "swupdate-$k" "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate "$k" 2>/dev/null || echo unset)"
done

row auto-login-user "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo none)"
row guest-enabled "$(defaults read /Library/Preferences/com.apple.loginwindow GuestEnabled 2>/dev/null || echo unset)"
for k in LoginHook LogoutHook; do
  row "$k-user" "$(defaults read com.apple.loginwindow "$k" 2>/dev/null || echo none)"
  row "$k-system" "$(defaults read /Library/Preferences/com.apple.loginwindow "$k" 2>/dev/null || echo none)"
done

# Accounts. dscl prints "eServerError" when the sandbox blocks directory services.
if out=$(probe dscl . list /Users UniqueID); then
  row users "$(printf '%s\n' "$out" | awk '$2>=500 || $2==0 {print $1"("$2")"}' | tr '\n' ' ')"
else
  row users "$out"
fi
if out=$(probe dscl . read /Groups/admin GroupMembership); then
  row admins "$(printf '%s' "$out" | sed 's/^GroupMembership: //')"
else
  row admins "$out"
fi
if out=$(probe dscl . list /Users IsHidden); then
  row hidden-users "$(printf '%s\n' "$out" | awk '$2==1{print $1}' | tr '\n' ' ')"
else
  row hidden-users "$out"
fi
# The group exists without a GroupMembership key when nobody is restricted to it.
out=$(dscl . read /Groups/com.apple.access_ssh GroupMembership 2>&1)
case "$out" in
  *"No such key"*|*"eDSRecordNotFound"*) row ssh-access-group "none (any admin can log in when Remote Login is on)" ;;
  *eServerError*) row ssh-access-group "DENIED: $out" ;;
  *) row ssh-access-group "$(printf '%s' "$out" | sed 's/^GroupMembership: //')" ;;
esac

# sudoers drop-ins: names and dates only. Their contents are root-only.
for f in /etc/sudoers.d/*; do
  [ -e "$f" ] || continue
  row sudoers.d "$(basename "$f") modified $(mtime "$f") owner $(stat -f '%Su' "$f")"
done

# Remote access services. "enabled" in the disabled-services list means the service may start.
disabled=$(launchctl print-disabled system 2>&1) || disabled="DENIED"
svc() {
  local v
  [ "$disabled" = DENIED ] && { echo "DENIED: launchctl print-disabled failed"; return; }
  v=$(printf '%s\n' "$disabled" | grep "\"$1\"" | sed 's/.*=> //' | head -1)
  echo "${v:-default (off unless turned on in Sharing settings)}"
}
row remote-login "$(svc com.openssh.sshd || true)"
row screen-sharing "$(svc com.apple.screensharing || true)"
row remote-apple-events "$(svc com.apple.AEServer || true)"
row file-sharing-smb "$(svc com.apple.smbd || true)"
pgrep -x ARDAgent >/dev/null 2>&1
case $? in 0) row ard-agent-running yes ;; 1) row ard-agent-running no ;; *) row ard-agent-running "DENIED: pgrep failed" ;; esac
if out=$(probe sharing -l); then
  row sharing-points "$(printf '%s\n' "$out" | grep -c '^name:' | tr -d ' ')"
else
  row sharing-points "$out"
fi

row profiles "$(probe profiles list | head -3 | tr '\n' ' ')"
row mdm-enrollment "$(probe profiles status -type enrollment | tr '\n' ' ')"
row managed-preferences "$(ls '/Library/Managed Preferences' 2>/dev/null | tr '\n' ' ')"
row lockdown-mode "$(defaults read .GlobalPreferences LDMGlobalEnabled 2>/dev/null || echo off)"
lock=$(sysadminctl -screenLock status 2>&1 | sed -n 's/.*screenLock delay is //p' | head -1)
row screen-lock-delay "${lock:-DENIED: sysadminctl gave no answer}"
