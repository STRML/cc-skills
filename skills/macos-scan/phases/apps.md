# Apps and processes

```bash
"$S/apps.sh"  > "$SCAN_DIR/apps.tsv"    # every .app in /Applications and ~/Applications, one folder deep
"$S/tcc.sh"   > "$SCAN_DIR/tcc.tsv"     # privacy grants from the system and user TCC databases
"$S/procs.sh" > "$SCAN_DIR/procs.tsv"   # running executables outside macOS, with signatures
```

Homebrew formulae and casks and Mac App Store apps are inventoried in the packages phase.

## apps.tsv

Columns: `kb|path|bundle_id|version|signer|team|gatekeeper|last_used|date_added|app_store|quarantine`. `gatekeeper` is `accepted` or `rejected` plus the source (`Notarized Developer ID`, `Mac App Store`, `Apple System`, `Unnotarized Developer ID`, `none`).

Flag:

- `UNSIGNED` or `ADHOC` apps that are not owner-built, games or open-source tools the user knowingly built, especially with `quarantine=no` and a recent `date_added`. An app with no quarantine flag that was not installed from the App Store, Homebrew or a `.pkg` had its flag stripped, which is the step a "paste this into Terminal" lure asks for (AMOS runs `xattr -c`).
- a signer that does not match the app's maker. Check crypto wallet apps (Ledger Live, Trezor Suite, Exodus, Electrum) and utilities that have shipped trojanized copies (The Unarchiver, Presentify, PDFify, Magic Disk Cleaner, SiteSucker Pro, RAR Extractor Max, Mp3tag, HextEdit, ServerCat, Bartender) by name.
- an app named after a system app (Finder, Terminal, System Settings) outside `/System/Applications`. The history phase lists these as `lookalike-app`.
- `Apple iPhone OS Application Signing`: an iPhone or iPad app running on Apple silicon. Fine when the user installed it from the App Store.

## tcc.tsv

Columns: `db|service|client|auth|target|last_modified`. A `DENIED` row means the database could not be read: on macOS 27 the user database stays unreadable even with Full Disk Access. Say so in the report; the user can review grants in System Settings > Privacy & Security.

Flag a client holding `Accessibility`, `ListenEvent` (Input Monitoring), `ScreenCapture`, `SystemPolicyAllFiles` (Full Disk Access), `PostEvent` or `AppleEvents` (Automation, with the target app) when the app has no clear reason for it, the app is gone, or the grant is recent and unexplained. Name the grant in plain words in the report ("can read every file", "can see your screen", "can type for you").

`/usr/libexec/sshd-keygen-wrapper` with Full Disk Access means Remote Login gives SSH sessions full disk access.

## procs.tsv

Columns: `signer|team|gatekeeper|pids|max_cpu|user|path|flags`. One row per executable, Apple-signed system code excluded.

Flag:

- `UNSIGNED` or `ADHOC` executables that are not Homebrew builds, language runtimes or owner-built tools
- anything running from a temp folder, `/Users/Shared`, Downloads, a hidden folder or the Trash (`trash-path`: an app was dragged to the Trash while its helper kept running)
- `high-cpu` on an executable the user cannot name (miners); sustained, not a one-off build
- `binary-deleted` on an executable that was not just updated

## Known false alarms

- Simulator runtimes (`CoreSimulator/Volumes/*/RuntimeRoot`) are Apple-signed system code and are skipped.
- `binary-deleted` right after `brew upgrade` or an app update: the old process still runs from the replaced file. Check `brew list --versions` or the app's version.
- `name-is-not-an-executable`: Wine and some Electron apps set the process name to a file that is not the executable. Confirm the real binary with `lsof -p <pid> -d txt`.
- Homebrew formulae, `uv` and `pyenv` Pythons, Node from version managers and Go or Rust tools the user built are ad-hoc signed by design.
- Many apps share one `date_added`: a macOS upgrade or migration rewrote it. It is not an install date (see the unused phase).
