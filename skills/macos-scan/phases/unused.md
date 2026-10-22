# Unused apps

Needs `apps.tsv` from the apps phase. `persistence.tsv` and `procs.tsv` are optional and mark apps that autostart or are running.

```bash
"$S/unused.sh" "$SCAN_DIR/apps.tsv" "$SCAN_DIR/persistence.tsv" "$SCAN_DIR/procs.tsv" 90 > "$SCAN_DIR/unused.tsv"
```

Rows: `status|kb|app|last_used|days_idle|autostart|running`, sorted by status, then size.

- `unused`: Spotlight's last-used date is older than the threshold (90 days by default). Rank these by size. These are the candidates.
- `no-usage-record`: Spotlight has no date. That is not "never used": apps launched from the command line, by a helper, or never indexed have no date. Do not rank these as unused. List the big ones separately and ask the user.
- `recent`: used within the threshold.
- `warning`: one `date added` covers most apps. A macOS upgrade or migration rewrote it, so date added cannot stand in for age. When most apps are `no-usage-record` and this warning appears, say the ranking cannot be computed for those apps instead of guessing.

An unused app that autostarts or keeps a background process is worth a line even when it is small: it costs memory and keeps an update channel open.

## Reclaim

For each app the user agrees to remove, give the command and what it leaves behind:

- the vendor's uninstaller when there is one (it removes helpers and launch items)
- `brew uninstall --cask --zap <cask>` for Homebrew casks
- otherwise move the app to the Trash, then list its leftovers by bundle id in `~/Library/Application Support`, `~/Library/Caches`, `~/Library/Containers`, `~/Library/Preferences` and any launch items or helper tools from the persistence phase

Wait for the user's go-ahead before running any of it.
