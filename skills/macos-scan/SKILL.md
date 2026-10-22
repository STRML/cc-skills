---
name: macos-scan
description: Read-only security, malware, unused-app and disk-space audit of the Mac you are running on. Checks security settings, everything that autostarts, apps and their privacy permissions, browser extensions, network listeners and trusted certificates, installed packages against CVE and malicious-package databases, traces of known macOS malware, unused apps, and what is filling the disk. Use whenever the user asks to scan, audit, or check their Mac for malware, viruses, spyware, infostealers, suspicious software, risky permissions, or vulnerable packages, or asks what is using their disk space or which apps they never use, even if they only say "is my Mac OK" or "clean up my Mac".
argument-hint: "[all | security | posture | persistence | browsers | apps | network | packages | history | unused | disk]"
---

# /macos-scan

A read-only audit of this Mac. Collector scripts gather raw rows into a scan folder, you judge them against the phase files, and the user gets a ranked report with exact fix commands. Nothing is changed, removed or uploaded until the user says go.

```
argument ─▶ phase files ─▶ scripts/*.sh (read-only) ─▶ $SCAN_DIR/*.tsv
                                                         │
                       report ◀─ rank + verify leads ◀───┘
   (findings, verdict, skipped checks, reclaim table)
```

## Pick the phases

| Argument | Phases (read each file before running it) |
|---|---|
| `all` (default) | every phase below |
| `security` | posture, persistence, browsers, apps, network, history, packages |
| `posture` | [phases/posture.md](phases/posture.md) |
| `persistence` | [phases/persistence.md](phases/persistence.md) |
| `browsers` | [phases/browsers.md](phases/browsers.md) |
| `apps` | [phases/apps.md](phases/apps.md) |
| `network` | [phases/network.md](phases/network.md) |
| `packages` | [phases/packages.md](phases/packages.md) |
| `history` | [phases/history.md](phases/history.md) |
| `unused` | apps, then [phases/unused.md](phases/unused.md) |
| `disk` | [phases/disk.md](phases/disk.md) |

The phases are independent. With several of them, fan them out to subagents, one phase each. Give each subagent its phase file, the ground rules below, and `$SCAN_DIR`, and ask for findings rather than raw rows. `unused` reads the apps phase output, so run apps first. Measured on a busy developer Mac: posture, network, browsers, devchain, packages inventory and repos under a minute each; persistence about 1 minute; procs and history with `--logs` about 1.5; apps about 3; artifacts about 6; disk `known` 1.5, `files` 4, `top` over 5. The OSV scan adds minutes for database downloads on a first run.

## Ground rules

These apply to every phase and every subagent.

- **Read-only.** Never change, delete, quarantine, kill, unload or upload anything. Removal commands go in the report, and run only after the user says go.
- **Names and paths only.** Never print file contents, keychain items, tokens, passwords, environment variables or command arguments. Report pattern names, line numbers, dates and paths. When you must judge what a script or a history line does, read it through `redact` from `scripts/lib.sh` (`sed -n '<line>p' <file> | (. "$S/lib.sh"; redact)`) and state a one-line summary in the report, never its lines. The same goes for any command line that has to appear anywhere (a process, a listener, a launch item): model servers and CLIs take `--api-key <value>` on the command line. `scripts/selftest.sh` checks what `redact` masks.
- **No inventory leaves the Mac.** No hash lookups, no package lists or app lists sent to online services. Downloading public databases (OSV, the CISA KEV catalog) and the pinned osv-scanner binary is fine, because the matching runs locally. A research subagent may look up an app's advisories by name and version only.
- **Never walk `/` or `~`.** No `find`, `rg`, `du` or `fd` rooted at `/` or the home folder. Cloud mounts under `~/Library/CloudStorage` and iCloud Drive are network-backed, and a recursive walk pins the machine. The scripts walk the home folder's children one at a time, skip other devices, and wrap slow commands in `timeout`.
- **Denied is not clean.** When a check is blocked (sandbox, Full Disk Access, root, a protected folder), record it as denied and list it in the report. Never report "nothing found" for a check that could not look.
- **"Recent" means added or modified in the last 30 days.**
- **Owner-built tools are not threats by default.** Binaries and launch items that run code from the user's own code directories (or a tool the user names) are listed, and flagged only when something about them is off: a path that moved, a script that downloads and runs code, a signature that changed.

## Set up

1. Set `SCAN_DIR` to the session scratchpad if the harness provides one, otherwise `$TMPDIR/macos-scan-<date>`, and create it. Raw rows go there; the chat gets findings.
2. Set `S` to this skill's `scripts/` directory. Every script prints its usage with `-h` and prints pipe-delimited rows with a header. The scripts put the system tool folders first in `PATH`, add Homebrew and per-user tool folders after them, and fall back to perl when `timeout` is missing, so they run on a stock Mac and over `ssh 'bash -s'`. A blocked check prints a `DENIED` or `skipped` row; a timed-out walk prints `skipped ... timed out`.
3. Ask the user which folders hold their code (for the repo and lockfile checks). Default to `~/code`, `~/src`, `~/Projects`, `~/Developer` and `~/git`, whichever exist.

### Inside the Claude Code sandbox

The sandbox blocks several read-only system queries. `dscl`, `fdesetup` and `sharing` fail with `eServerError`; `launchctl print`, `codesign` on system paths, `log show` and the TCC database need to run outside it. Run the collectors with the sandbox bypass. They only read.

The exception is `osv.sh scan-installed` and `scan-lockfiles`: run them inside the sandbox with only `osv-vulnerabilities.storage.googleapis.com` allowed (see the packages phase), so no package name can reach another service. `osv.sh fetch` needs `github.com` and its download host.

### Scanning another Mac over SSH

The collectors run on a remote Mac without copying anything there: put `lib.sh` in front of the collector and pipe both to `bash -s`.

```bash
cat "$S/lib.sh" "$S/posture.sh" | ssh <host> 'bash -s' > "$SCAN_DIR/<host>-posture.tsv"
cat "$S/lib.sh" "$S/repos.sh"   | ssh <host> 'bash -s -- ~/code' > "$SCAN_DIR/<host>-repos.tsv"
```

`artifacts.sh` also needs `ioc-paths.txt`; over a pipe it prints a `skipped` row for the IOC check unless the scripts folder exists on the remote and `IOC_FILE` points at it. The slow phases (disk, the OSV scan) are better run as a batch on the remote. Keep every file in one dated scratch folder there and remove it when done:

1. `ssh <host> 'mkdir -p "$TMPDIR/macos-scan-<date>"'` and note the path it resolves to.
2. Copy the scripts through ssh stdin: `tar -C "$S" -cf - . | ssh <host> 'tar -C "<remote dir>" -xf -'`.
3. Run the phase there, writing into the same folder. On a shared machine with a job scheduler or queue, submit it through that instead of running it directly.
4. Copy the results back with `scp <host>:"<remote dir>/*.tsv" "$SCAN_DIR/"`.
5. Remove the remote folder (`trash` if the remote has it, otherwise `rm -r` on that one path, after checking the path you are about to remove contains `macos-scan-`) and say in the report that you did.

Over SSH, the system TCC database is denied unless `sshd-keygen-wrapper` has Full Disk Access, and anything that sends Apple events (an `osascript` login-items query) fails with -1743. Report both as denied. Root-only checks still need the user to run `sudo` on the remote.

### Checks that need root

The skill never runs `sudo`. Hand these to the user as one block to run (in Claude Code, prefix each line with `!` so the output lands in the session), each writing into `$SCAN_DIR`:

```bash
sudo sfltool dumpbtm > "$SCAN_DIR/btm.txt"
sudo profiles list -all > "$SCAN_DIR/profiles-all.txt"
sudo crontab -l > "$SCAN_DIR/root-crontab.txt" 2>&1
sudo ls -la /usr/lib/cron/tabs > "$SCAN_DIR/cron-tabs.txt" 2>&1
sudo -l > "$SCAN_DIR/sudo-l.txt"
sudo lsof -nP -iTCP -sTCP:LISTEN > "$SCAN_DIR/listeners-root.txt"
sudo lsof -nP -iUDP > "$SCAN_DIR/udp-root.txt"
```

Little Snitch adds two more (see [phases/network.md](phases/network.md)). Write the commands with the real `$SCAN_DIR` path filled in: the user's shell does not have your variables. If the user skips them, list those checks as skipped.

### Permissions that change results

- Full Disk Access for the terminal app opens the system TCC database, Mail, Messages and Safari data. On macOS 27 the user TCC database stays unreadable even with it.
- Apps can protect their own `~/Library/Application Support/<app>` folder, so a browser's profile can read as empty. Report that browser as denied.
- Spotlight must be on for last-used dates. `mdutil -s /` shows whether it is.

## Flag

Each phase file lists what to flag and the known false alarms for its area. Across phases, these are the strongest signals:

- unsigned, ad-hoc or unnotarized binaries that autostart, especially from `/tmp`, `/Users/Shared`, `~/Downloads`, a hidden folder or the Trash
- launch items whose label imitates Apple or a big vendor (`com.apple.*` not signed by Apple, `*.service`, `*.system`, `launched.*`)
- a known malware path from [references/iocs.md](references/iocs.md), or a package on the OpenSSF malicious-packages list
- apps with Accessibility, Screen Recording, Input Monitoring, Full Disk Access or Automation and no clear reason to have it
- listeners on all interfaces that the user cannot name, a proxy or DNS server they did not set, a trusted root certificate or configuration profile they did not install
- browser extensions installed by policy or sideloaded, native messaging hosts pointing at unsigned binaries
- shell history showing a pasted `curl | sh`, a quarantine strip or an `osascript` password prompt, or a history file that was wiped
- unknown local or admin accounts, Remote Login with full disk access for remote users
- anything recent that the user does not recognise (give its date)

A lead is not a finding until you have checked it: signature and notarization, where it came from, when it arrived, and whether the user installed it. Say which leads you cleared and why in one line each.

## Report

Write the report to `$SCAN_DIR/report.md` and give the user the findings in chat.

1. **Ranked findings**, most worrying first. For each: what it is in plain words, why it matters, the evidence (path, signer, date), the exact commands to disable and remove it, and what to secure afterward (passwords, 2FA, SSH keys, API tokens, browser sessions, crypto wallets). Removal commands start with the reversible step: `launchctl bootout`, then moving files to the Trash, never `rm -rf`.
2. **Verdict** on security: clean, suspicious or compromised, with one sentence of reasoning.
3. **Skipped or denied checks**, each with how to unblock it (grant Full Disk Access, run the root block, turn on Spotlight).
4. **Reclaimable space** as a table: item, allocated size, class (regenerates, re-downloadable, data), and the command. Wait for the user's go-ahead before running any of it.

Do not run any removal or cleanup command until the user approves it, item by item or as a named batch.
