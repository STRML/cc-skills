# Persistence: what starts on its own

```bash
"$S/persistence.sh" > "$SCAN_DIR/persistence.tsv"    # launchd, helpers, extensions, cron, shell startup
"$S/devchain.sh"    > "$SCAN_DIR/devchain.tsv"       # editor extensions, MCP servers, agent hooks, taps, git
"$S/repos.sh" <code dirs> ~/Downloads > "$SCAN_DIR/repos.tsv"   # git hooks, Xcode scripts, auto-run tasks
```

Dock entries, Folder Actions, directory-service plugins and screen savers come from `artifacts.sh` in the history phase.

## persistence.tsv

Columns: `kind|scope|item|label|modified|loaded|program|signer|team|gatekeeper|flags`.

| Kind | What it is |
|---|---|
| `launchd` | a plist in `/Library/LaunchDaemons`, `/Library/LaunchAgents` or `~/Library/LaunchAgents`. `program` shows the binary, plus the script when the binary is an interpreter |
| `launchd-no-plist` | a job loaded in the user's launchd domain with no plist on disk |
| `helper-tool` | a privileged helper in `/Library/PrivilegedHelperTools` (runs as root) |
| `auth-plugin` | a login-window authorization plugin (sees passwords at login) |
| `kext-installed`, `kext-loaded`, `system-extension` | kernel and system extensions, including network filters and camera drivers |
| `app-extension` | Finder sync, Quick Look, Safari and widget extensions from `pluginkit` |
| `cron`, `at`, `periodic` | scheduled jobs. Only the program path of each cron line is printed |
| `launchd-env` | a `DYLD_*` variable set in launchd (injects a library into every process) |
| `shell-startup` | zsh, bash and fish startup files, `/etc/zshrc`, `/etc/profile` and `/etc/paths.d`, with the line numbers of risky patterns |

Flags the script sets: `interpreter` (a shell, Python, osascript or similar runs a script), `risky-args` (curl, wget, nc, eval, base64, osascript or `python -c` in the arguments), `tmp-path`, `hidden-path`, `downloads-path`, `users-shared-path`, `trash-path`, `script-*` (the same, for the script an interpreter runs), `missing-binary`, `missing-script`, `stub-plist`, `unreadable`, `apple-name-not-apple-signed`, `adload-style-label` (`*.service`, `*.system`, `launched.*`), `self-hosted-runner` (`actions.runner.*`), `dyld-env`, `recent`.

Flag:

- a launch item with `apple-name-not-apple-signed`, `adload-style-label`, `dyld-env`, or a program in a temp, hidden, shared or Downloads path
- an `UNSIGNED` or `ADHOC` program that is not owner-built
- `interpreter` with `risky-args`, or a script outside the user's own code directories
- a label or plist name from [../references/iocs.md](../references/iocs.md)
- a recent item the user does not recognise
- an `auth-plugin` the user did not install on purpose (remote-support tools add them)
- `shell-startup` files with pattern lines: read those lines through `redact` (`sed -n '<line>p' <file> | (. "$S/lib.sh"; redact)`), summarise what they do in one line, and never quote them
- `launchd-env` rows of any kind

### Login and background items

`sfltool dumpbtm` lists every login item and background item with its developer name and URL, but only as root; without root it prints only the UID -2 records. Ask for it (root block in SKILL.md). In `btm.txt`, flag entries whose URL points under `~/Library`, `/tmp` or a hidden folder, and entries with an empty Developer Name. Some stealers (PamStealer) kill the background-item notification agent, so "I never saw a login-item alert" is not evidence of anything.

## devchain.tsv

Columns: `kind|source|name|detail|modified`. Editor extensions (VS Code, Cursor, Windsurf, Zed), MCP servers from every agent client, agent hooks, GitHub Actions self-hosted runners, Homebrew taps and global git settings. MCP rows show the server name and the program or package it launches. Never print an MCP server's arguments or environment; they hold API keys.

Flag:

- an MCP server launched with `npx`, `uvx` or `bunx` from a package the user cannot name, or pointed at a remote URL they do not recognise (malicious MCP servers have shipped on npm)
- an agent hook that runs a script outside the user's own config or code directories
- an editor extension from an unfamiliar publisher, installed recently
- a `self-hosted-runner` row, or a launch item flagged `self-hosted-runner`: workflows from the repository or organisation in `detail` run code on this Mac. If that repository is public, a pull request from a fork can run here too. Check its workflows for `pull_request` or `pull_request_target` triggers with `runs-on: self-hosted`, and report the runner even when the triggers look safe
- a third-party Homebrew tap the user does not remember adding
- `core.hooksPath`, `core.fsmonitor`, `core.sshCommand` or `init.templateDir` set globally to something unfamiliar: each runs code on ordinary git commands

## repos.tsv

Columns: `kind|path|detail|modified`. Scans the code folders and Downloads for active git hooks, per-repo `core.hooksPath`, Xcode shell-script build phases that use `xxd`, `base64`, `curl` or `osascript` (XCSSET), VS Code tasks with `runOn: folderOpen` (the "contagious interview" fake job repos), Shai-Hulud worm workflows, and project MCP configs.

Flag every `vscode-autorun-task`, `xcode-build-script` and `worm-workflow` the user did not write. Git hooks from Husky, lefthook, pre-commit and git-lfs are normal; flag hooks in a repo cloned from a stranger, or a hook that downloads code (read it, summarise in one line).

## Known false alarms

- `spctl` reports "rejected" for bare Mach-O helpers in `/Library/PrivilegedHelperTools` and kernel extensions even when they are notarized. Judge them by the signer, the `Notarized Developer ID` source and the parent app.
- 181-byte plists with no label (Google Keystone, Dropbox updater) are inert placeholders that block an old updater. `stub-plist` marks them.
- An `unreadable` plist owned by root with mode 600 is usually a vendor updater. Check the vendor's app is installed.
- `launchd-no-plist` rows are mostly apps registering helpers through `SMAppService`, Electron `ShipIt` updaters and `ssh-agent`. Flag only names the user cannot tie to an installed app.
- Homebrew services (`homebrew.mxcl.*`) run ad-hoc-signed binaries; that is how Homebrew builds them.

<!-- TRADECRAFT: additions from the threat research go here. Keep each item a check
     with a command, a family and a source URL; put file paths in ../references/iocs.md. -->
