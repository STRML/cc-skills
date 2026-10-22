# Browsers: extensions, policies, native hosts

```bash
"$S/browsers.sh" > "$SCAN_DIR/browsers.tsv"
```

Columns: `kind|browser|profile|id|name|version|modified|source|risky-permissions`. The script covers every profile of Chrome (and Beta, Canary), Arc, Brave, Edge, Chromium, Vivaldi, Opera and other Chromium browsers it finds, Firefox, and Safari extensions registered through app bundles. It resolves `__MSG_` names from each extension's locale files.

| Kind | What it is |
|---|---|
| `extension` | one extension in one profile. `source` comes from the browser's own record: `webstore-or-user`, `not-from-webstore`, `unpacked-sideload`, `policy-forced`, `external-pref*`, `component` |
| `native-host` | a JSON file that lets an extension start a local program. `name` holds the target binary and `source` its signer |
| `policy` | a managed or preference plist that sets extension, proxy, homepage or search keys (key names only) |

Flag:

- `policy-forced` or `unpacked-sideload` extensions the user did not install on purpose, and any `policy` row they did not set up. Adware installs extensions through policy so the user cannot remove them.
- an extension with `<all_urls>` or `*://*/*` plus `cookies`, `webRequest`, `debugger` or `nativeMessaging` that the user does not recognise. Those can read every page and steal session cookies.
- crypto wallet extensions (MetaMask, Phantom and others): not a threat, but name them in the report, since stealers target them and they raise the stakes of any other finding.
- a `native-host` whose target is missing, unsigned, ad-hoc, or in a temp or hidden folder.
- recent extensions with generic names ("PDF Converter", "Video Downloader") or names that imitate a known extension.
- more than one password manager extension: not a threat, but worth one line (stale ones keep old vault sessions alive).

Browsers started with `--load-extension`, `--remote-debugging-port` or `--headless` show up in the history phase (`browser-remote-flags`). Stealers use those flags to hijack sessions; automation tools and agent browsers use them legitimately.

## Known false alarms

- `component` and `external-component` entries (Chrome Web Store Payments, Google Docs Offline) ship with the browser.
- `external-pref-download` entries are installed by another app's preference file: Google Drive, Office and password managers do this.
- An empty result for a browser the user uses means the profile folder was unreadable (macOS 27 lets apps protect their Application Support folder). Report it as denied.
