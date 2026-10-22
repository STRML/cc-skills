# Posture: security settings

Run outside the sandbox (directory services and `fdesetup` are blocked inside it):

```bash
"$S/posture.sh" > "$SCAN_DIR/posture.tsv"
```

| Row | Healthy value | Flag when |
|---|---|---|
| `sip` | enabled | disabled or custom configuration |
| `gatekeeper` | assessments enabled | disabled |
| `filevault` | On | Off. On an always-on machine (a server or build Mac) Off may be a deliberate choice so it can reboot unattended; ask the user, report it either way, and lower the severity if they confirm |
| `firewall`, `firewall-stealth` | enabled | off on a laptop that joins public networks (lower severity on a desktop behind a router) |
| `xprotect` | a version installed in the last few weeks | months old: background updates are not arriving |
| `swupdate-*` | 1 for CriticalUpdateInstall and ConfigDataInstall | 0: XProtect and security responses will not install |
| `auto-login-user` | none | any user, with FileVault off |
| `LoginHook-*`, `LogoutHook-*` | none | any value: deprecated, so a present hook is unusual |
| `users`, `admins`, `hidden-users` | accounts the user recognises | an unknown account, an unknown admin, a hidden user that is not a known service account |
| `sudoers.d` | files from tools the user installed | a file they do not recognise, or a recent one. Contents are root-only: ask for `sudo -l` (root block in SKILL.md) to see NOPASSWD rules and `timestamp_timeout` |
| `remote-login` | default (off) | enabled and the user does not use SSH into this Mac |
| `screen-sharing`, `remote-apple-events`, `file-sharing-smb`, `ard-agent-running` | default (off), no | on and unexplained. Remote Apple Events lets another Mac script this one |
| `profiles`, `mdm-enrollment` | none, No | a profile or enrollment the user did not set up. Ask the user for `sudo profiles list -all`: the unprivileged list shows only user profiles |
| `lockdown-mode` | either | informational |

Remote Login also shows up in the system TCC database: `/usr/libexec/sshd-keygen-wrapper` holding Full Disk Access (apps phase) means "Allow full disk access for remote users" is on. Flag that when Remote Login is on and the user does not need it.

Detections by XProtect Remediator and Gatekeeper live in the unified log. The history phase reads them, along with how far back the log reaches.

## Known false alarms

- `guest-enabled = 1` and a `Guest` folder under `/Library/Managed Preferences` are the stock guest account with its parental-controls plist. That is not MDM.
- `xprotect version` works unprivileged on macOS 27.0.1 but may need `sudo` on other versions. The active data lives in `/private/var/protected/xprotect`.
- `emond` was removed in macOS 13 and the Dock tile plugin privilege escalation was fixed in 14.4. Do not check for either.
