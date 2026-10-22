# History: traces of what already ran

Persistence shows what will run next time. This phase looks for what already happened: known malware files, pasted commands, stripped quarantine flags, logins, and detections.

```bash
"$S/artifacts.sh" > "$SCAN_DIR/artifacts.tsv"           # about 6 minutes
"$S/history.sh" --logs > "$SCAN_DIR/history.tsv"        # add --days N to change the 30-day window
```

## artifacts.tsv

Columns: `kind|path|detail|modified`. Contents are never read; the script checks existence, signatures, extended attributes and dates.

| Kind | Flag when |
|---|---|
| `ioc-hit` | always: a path from [../references/iocs.md](../references/iocs.md) exists. Verify before reporting (signature, contents summary, date); several paths are generic enough to collide with real software |
| `suid-sgid` | set-user-ID files outside the system volume that are unsigned, ad-hoc, or not part of an app the user installed |
| `download-exec` | an app, installer or executable in Downloads with `quarantine=no`: something removed the flag |
| `hidden-home` | a hidden executable directly in the home folder, or a hidden folder created recently that no installed tool explains (`~/.agent`, `~/.mainhelper`, `~/.n2` and `~/.gps` are known malware names; `~/.task` is too, but Taskwarrior uses it for its data, so check what is inside) |
| `app-in-data-dir` | an unsigned or ad-hoc app bundle inside Application Support, Caches, `/tmp`, `/private/var/tmp` or `/Users/Shared` that is not a build output the user recognises. Stealers park their payload there (PamStealer, CrashStealer, ChillyHell, XCSSET) |
| `hidden-in-bundle` | a hidden file inside an app's `Contents/MacOS` (a trojanized installer leaves one) |
| `lookalike-app` | a non-Apple app named Finder, Terminal, System Settings or similar (XCSSET) |
| `shared-tmp` | hidden entries or Mach-O executables in `/Users/Shared`, `/private/var/tmp` or `/tmp` the user cannot explain |
| `dock-item` | a Dock entry that points outside `/Applications` and `/System` (XCSSET and RustDoor replace Dock items) |
| `folder-actions-enabled`, `plugin-dir` | Folder Actions turned on, or scripts, directory-service plugins or screen savers the user did not add |
| `pkg-receipt` | an installer package the user does not recognise, especially a recent one (PasivRobber shipped as a `.pkg`) |
| `authorized-key` | an SSH key the user does not recognise: it can log in to this Mac when Remote Login is on. Fingerprints only |
| `browser-remote-flags` | a browser running with `--load-extension`, `--remote-debugging-port` or `--headless` that is not an automation tool the user runs (AmnesiaStealer hijacks sessions this way) |
| `secret-in-args` | a running process took a secret-looking flag (`--api-key`, `--token`, `--password`) on its command line. Low severity: any local user can read it with `ps`. Only the flag name is printed |
| `download-origin` | a download host the user does not recognise in the last 30 days. Some browsers (Arc) record no URL |

## history.tsv

Columns: `kind|source|where|when|detail`.

- `history-hit`: a shell history line matched a pattern. The row has the file, line number, time when the shell records it, and the pattern name, never the command. Patterns: `curl-pipe-shell`, `quarantine-strip`, `base64-pipe`, `osascript-inline`, `hidden-answer-prompt`, `gatekeeper-off`, `authorization-check` (`dscl -authonly`, how stealers test a stolen password), `history-wipe`, `tmp-exec`. Read the matching lines through `redact` (`sed -n '<line>p' <file> | (. "$S/lib.sh"; redact)`), decide whether the user typed them knowingly (installing Homebrew is a `curl-pipe-shell`), and summarise any you cannot explain in one line. A recent `curl-pipe-shell` the user does not remember, especially next to a `quarantine-strip` or `osascript-inline`, is the "paste this into Terminal" lure and a top finding.
- `history-empty`: an empty history file. Some stealers run `history -c`; an empty file is not a clean one.
- `login-record`: recent logins from `last`, including SSH sessions. Flag remote logins the user did not make.
- `log-retention`: the date of the oldest persistent log file. Full log records often reach back only a few days. State the real window in the report instead of claiming 30 days of coverage.
- `xprotect`: a remediator result other than "no threat". Report each one. `xprotect-runs` counts clean results; zero means no scan fell inside the log window, not that XProtect is off.
- `ssh-login`: accepted SSH logins by user and source address.
- `tcc-osascript`: `osascript` asked for a privacy permission. Stealers drive Finder through osascript to copy files.

## Known false alarms

- Homebrew, rustup, nvm, Bun and Oh My Zsh install with `curl ... | sh`. Match the time with when the user set up that tool.
- `xattr -cr` on an app the user built or downloaded from a developer they trust is a common workaround. It still disables Gatekeeper for that app; mention it once.
- Developer tools put hidden folders in the home folder all the time. Judge by name, date and whether a known tool explains it.

<!-- TRADECRAFT: additions from the threat research go here. Keep each item a check
     with a command, a family and a source URL; put file paths in ../references/iocs.md. -->
