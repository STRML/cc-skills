# Known macOS malware paths

`scripts/ioc-paths.txt` holds the same paths in machine-readable form; `artifacts.sh` checks each one for existence only. Keep the two files in sync.

A hit is a lead. Several names (`~/.agent`, `~/.task`, `com.zoom.plist`) are generic enough that real software could use them. A third field in `ioc-paths.txt` narrows a glob with a file-name regex (AdLoad's folders are a dot followed by digits only). Check the signature, the date and what the file does before reporting it as malware.

**Verification status.** "Primary" means the paths were read from the vendor's own write-up. "Verify" means they came from a summarizing fetch of a long multi-family post (the Objective-See yearly reports); confirm the exact path against the source before treating a hit as a match.

| Family | Paths and names | Source | Status |
|---|---|---|---|
| PamStealer | `~/Library/Application Support/com.apple.finder.core/Finder.app`, `~/Library/Caches/com.apple.finder.core/`, `/private/tmp/System Settings`, LaunchAgent `com.apple.finder.agent`, `~/Library/Application Support/System/.repair-run`, `.sysnotif-backup.tgz`, a `# sysnotif-repair` line in `~/.zshrc` | [Jamf: PamStealer](https://www.jamf.com/blog/pamstealer-macos-infostealer-applescript-rust/), [Jamf: PamStealer Wavel](https://www.jamf.com/blog/pamstealer-wavel-macos-infostealer/) | Primary |
| CrashStealer | `~/Library/LaunchAgents/com.apple.crashreporter.helper.plist`, `~/Library/Caches/com.apple.crashreporter/CrashReporter.app`, `/private/tmp/.CrashReporter/`, `~/.cache/com.apple.crashreporter/` | [Jamf: CrashStealer](https://www.jamf.com/blog/crashstealer-macos-infostealer-analysis/) | Primary |
| AmnesiaStealer | `/tmp/.com.apple.dt.<digits>`, `~/.pwd`, `~/.local/share/.stream/`, `/tmp/.tcc_mod.db`; runs `history -c` | [Jamf: Amnesia Stealer](https://www.jamf.com/blog/amnesia-stealer-macos-infostealer-clickfix/) | Primary |
| AMOS / Odyssey | `/Library/LaunchDaemons/com.finder.helper.plist`, `~/.agent`, `~/.mainhelper`, `~/.pass`, `/tmp/.pass`, `/tmp/update`, `/tmp/out.zip`, `/tmp/pizda/`; strips quarantine with `xattr -c` | [Sophos: why AMOS matters](https://www.sophos.com/en-us/blog/why-amos-matters-the-macos-malware-stealing-data-at-scale) | Primary |
| FlexibleFerret | LaunchAgent `com.zoom.plist` running `/private/var/tmp/logd`; `/var/tmp/zoom`, `/var/tmp/InstallerAlert.app`, `/var/tmp/versus.app`; `com.driver9990as7tpatch.plist`. Key on ProgramArguments under `/private/var/tmp` | [SentinelOne: FlexibleFerret](https://www.sentinelone.com/blog/macos-flexibleferret-further-variants-of-dprk-malware-family-unearthed) | Primary |
| InvisibleFerret / BeaverTail | `com.avatar.update.wake.plist`; `~/.n2` | [MITRE S1245](https://attack.mitre.org/software/S1245), [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify `~/.n2` |
| Contagious Interview installers | `~/.task` (low confidence: Taskwarrior uses the same folder for its data, so check whether it holds `.data` files or an executable), a hidden `Contents/MacOS/.macos` inside an app, `/Library/Application Support/<app>Extra` | [Jamf: trojanized installers](https://www.jamf.com/blog/contagious-interview-trojanized-macos-installers/) | Primary |
| BlueNoroff | `com.telegram2.update.agent.plist`, `/Library/Application Support/Frameworks/Telegram 2`, `/Library/CloudKitDaemon` | [Objective-See 2025 report](https://objective-see.org/blog/blog_0x84.html) | Verify |
| ChillyHell | LaunchAgent or LaunchDaemon `com.apple.qtop`, `~/Library/com.apple.qtop/qtop` | [Objective-See 2025 report](https://objective-see.org/blog/blog_0x84.html) | Verify |
| PasivRobber | `/Library/LaunchDaemons/com.myam.plist`, `/Library/protect/wsus/bin/goed`; delivered as a `.pkg` | [Objective-See 2025 report](https://objective-see.org/blog/blog_0x84.html) | Verify |
| ZuRu | `com.apple.fsevents` launch item, `/Users/Shared/.fseventsd`, `libConfigurer64.dylib` inside a trojanized app | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| HiddenRisk | persistence through `~/.zshenv` | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| VShell | cron `@reboot` running `~/.gps` | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| EvasivePanda | `com.Terminal.us.plist` | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| InletDrift | `com.apple.systemextensions.cache.plist` | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| Activator | `launched.<UUID>.plist`; kills the background-item notification agent | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| Cthulhu | `/Users/Shared/NW/` | [Objective-See 2024 report](https://objective-see.org/blog/blog_0x7D.html) | Verify |
| XCSSET | `~/.zshrc_aliases`, `~/Library/Caches/com.apple.finder/` (also used by real Finder, so not in the path list), `~/.a`, `/tmp/.f`, `.git/hooks/pre-commit`, Xcode build phases using `xxd` | [Microsoft: new XCSSET](https://www.microsoft.com/en-us/security/blog/2025/03/11/new-xcsset-malware-adds-new-obfuscation-persistence-techniques-to-infect-xcode-projects/) | Primary |
| AdLoad | launch labels ending `.service` or `.system`, `~/Library/Application Support/.<digits>/Services/`, `.logg` files | [SentinelOne: AdLoad](https://www.sentinelone.com/labs/massive-new-adload-campaign-goes-entirely-undetected-by-apples-xprotect/) | Primary |

## Platform notes used by the phases

| Note | Source |
|---|---|
| macOS 27: the user TCC database is unreadable even with Full Disk Access | [Apple Developer Forums 841091](https://developer.apple.com/forums/thread/841091) |
| Apps can protect their Application Support folder (`com.apple.macl`), so another app's profile can read as empty | [Michael Tsai: Application Support protection](https://mjtsai.com/blog/2026/07/24/golden-gate-application-support-protection/) |
| XProtect's active data lives in `/private/var/protected/xprotect`; `xprotect version` may need sudo on some releases | [Eclectic Light: XProtect](https://eclecticlight.co/2026/09/16/what-has-happened-with-xprotect/) |
| The unified log often keeps full records for only a few days | [Eclectic Light: log retention](https://eclecticlight.co/2026/03/12/how-long-does-the-log-keep-entries/) |
| Little Snitch's `log`, `log-traffic` and `export-model` commands need root | [Little Snitch 6: command line](https://help.obdev.at/littlesnitch6/cmd-overview) |
