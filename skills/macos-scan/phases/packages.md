# Packages and vulnerabilities

Three sources, matched locally. Report in this order: malicious packages, then KEV leads you confirmed, then critical and high CVEs with the fixed version.

```
packages.sh inventory ─▶ what is installed (brew, npm, bun, pipx, uv, cargo, go, gem, App Store)
osv.sh scan-installed ─┐
osv.sh scan-lockfiles ─┴▶ OSV offline DB (CVEs + OpenSSF malicious packages) ─▶ osv.sh summarize
kev.sh match ─────────────▶ CISA KEV catalog ─▶ leads ─▶ version check per vendor advisory
```

## Inventory

```bash
"$S/packages.sh" inventory > "$SCAN_DIR/packages.tsv"
"$S/packages.sh" scan-dirs > "$SCAN_DIR/scan-dirs.txt"
```

`scan-dirs.txt` covers global npm trees for every Node install, Bun, pipx, uv tools, Cargo and Go binaries, `~/.local/bin` and Homebrew's `bin`. Append any Python virtual environments the user works in before scanning installed packages.

`packages.tsv` rows: `manager|name|version|location`. `brew-outdated` rows compare against the formula data from the last `brew update`; the script never runs `brew update` because it writes to Homebrew's checkout. Say how old that data is if it matters, and leave updating to the user. Third-party taps (`brew-tap` rows outside `homebrew/`) carry formulae nobody at Homebrew reviewed.

## OSV: CVEs and malicious packages

1. Fetch the pinned osv-scanner (v2.6.0). `osv.sh` refuses the download unless its SHA-256 matches the value pinned in the script, which was copied from the release's `osv-scanner_SHA256SUMS` when the pin was set. When bumping the pin, pick a release at least two weeks old and update the version and both hashes. The binary is ad-hoc linker-signed; that is normal for it.

   ```bash
   export OSV_HOME="$SCAN_DIR/osv"
   "$S/osv.sh" fetch
   ```

2. Scan installed packages, then lockfiles in the code folders. Run both under a network allowlist that permits only `osv-vulnerabilities.storage.googleapis.com` (in Claude Code: the sandbox with that host in the command's allowed domains). Even in offline mode osv-scanner reaches for `api.deps.dev` to resolve `requirements.txt` files and `proxy.golang.org` for Go call analysis. The script passes `--no-resolve` and turns call analysis off, and the allowlist catches anything left. Without resolution, a `requirements.txt` contributes only the packages it pins directly; say so when a project's only Python manifest is one.

   ```bash
   "$S/osv.sh" scan-installed "$SCAN_DIR/osv-installed.json" < "$SCAN_DIR/scan-dirs.txt"   # one dir per line
   "$S/osv.sh" scan-lockfiles "$SCAN_DIR/osv-lockfiles.json" <code dirs>
   "$S/osv.sh" summarize "$SCAN_DIR/osv-installed.json" "$SCAN_DIR/osv-lockfiles.json" > "$SCAN_DIR/osv-findings.tsv"
   ```

3. Check the scan worked before trusting a clean result. Every scan includes a canary lockfile with lodash 4.17.4; `summarize` prints `canary vulns=N|OK` and exits 2 with `BROKEN` when the canary comes back clean. Also check each `.log` for "unable to fetch OSV database": `--download-offline-databases` only fetches databases for ecosystems seen in that run, and a missing one makes the matcher return almost nothing without failing. Apply both checks to the installed-package scan as well as the lockfile scan. The summary line also counts advisories with no published severity score; they are left out of the table unless you run `UNSCORED=1 osv.sh summarize ...`. Mention the count, and list them when it is small.

`osv-findings.tsv` rows: `class|id|ecosystem|package|version|fixed_in|severity|source`.

Before calling a `malicious` row malware, find out where it lives:

- only in a lockfile: an old lockfile pins it. `MAL-2023-462` (fsevents before 1.2.11) appears in old lockfiles because that version downloaded a binary from a since-expired bucket. The fix is updating the lockfile; nothing ran unless the package was installed in that window.
- installed in a `node_modules` or site-packages folder: treat it as a real finding. It ran its install script.
- a `file:`, `link:` or `workspace:` package inside a monorepo: a local package whose name collides with a malicious public one (dependency confusion). It is a risk only if a registry install could ever pick the public name.

For CVE rows, group by project folder and give the fixed version. A CVE in a global tool the user runs daily matters more than one in an archived repo.

## KEV: known exploited vulnerabilities in apps

```bash
"$S/kev.sh" fetch "$SCAN_DIR/kev.json"
"$S/kev.sh" match "$SCAN_DIR/kev.json" "$SCAN_DIR/apps.tsv" > "$SCAN_DIR/kev-leads.tsv"
```

These are leads only. KEV entries carry no version ranges, so a row says the vendor's product once had an exploited bug, not that this Mac is vulnerable. The matcher already requires the KEV vendor to match the app's code-signing organisation (or the bundle-id vendor for App Store apps) and every distinctive product word to appear in the app's name or bundle id; matching on names alone produced junk (an Apple MIDI utility matched a VPN appliance, a remote-desktop client matched 175 Windows entries). For each lead, compare the installed version with the vendor's advisory for each CVE. Report a lead only when the installed version is older than the fix. A very old version (an Acrobat build from years ago) is worth reporting as "out of date" even without a matching KEV entry.

## Apps no database covers

For apps and casks with no OSV ecosystem and no KEV entry, a research subagent may check the vendor's security advisories. Send it only app names and versions, never paths, bundle ids or anything that identifies the user.
