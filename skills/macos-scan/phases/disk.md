# Disk space

```bash
"$S/disk.sh" known > "$SCAN_DIR/disk-known.tsv"              # caches, models, toolchains, VMs, backups
"$S/disk.sh" top   > "$SCAN_DIR/disk-top.tsv"                # biggest folders in ~ and ~/Library
"$S/disk.sh" files 500 > "$SCAN_DIR/disk-files.tsv"          # files over 500 MB
"$S/disk.sh" node_modules <code dirs> > "$SCAN_DIR/disk-node-modules.tsv"
"$S/disk.sh" snapshots > "$SCAN_DIR/disk-snapshots.tsv"      # Time Machine local snapshots
```

Rows: `section|kb|path|modified|class`. Every size is **allocated** size (`du -k`, or `stat` blocks for files), the space the disk actually holds. Never rank by logical size: a sparse VM disk can report terabytes while holding a few gigabytes, and cloud placeholders (OneDrive, iCloud, Dropbox) report files that are not on disk at all. `files` rows also show the logical size so the difference is visible.

The script never walks `~/Library/CloudStorage`, iCloud Drive or other mounted volumes, and it skips home-folder entries on another device (container mounts such as `~/OrbStack`).

Classes:

| Class | Meaning | Typical command |
|---|---|---|
| `regenerates` | caches and build output; tools rebuild them on demand | `brew cleanup -s`, `npm cache clean --force`, `uv cache clean`, `go clean -modcache`, `pnpm store prune`, deleting DerivedData |
| `redownloadable` | models, toolchains, device support files; free to delete, slow to get back | delete the model or toolchain by name (`ollama rm`, `rustup toolchain uninstall`) |
| `data` | the user's own files: VMs, backups, Messages attachments, Xcode archives, the Trash | the user decides; never suggest bulk deletion |
| `mixed` | simulators, container images and volumes | `xcrun simctl delete unavailable`, `docker system df` then a targeted prune |

The report's reclaim table lists item, allocated size, class and command, biggest first. Add `node_modules` folders in repos untouched for months as one grouped row. Time Machine local snapshots are purgeable: macOS frees them under pressure, so count them as "frees itself" rather than reclaimable.

Wait for the user's go-ahead before running any cleanup, and run it item by item or as a batch they named.
