# Network

```bash
"$S/network.sh" > "$SCAN_DIR/network.tsv"
```

Columns: `section|process|pid|detail|note`. No name lookups run (`lsof -n`), so remote addresses are IPs. Without root, `lsof` sees only sockets owned by this user, so sshd on port 22 and other root daemons are missing; the `scope` row says so. The root block in SKILL.md writes `listeners-root.txt` and `udp-root.txt` with every socket. Read those for the root-owned listeners.

| Section | Flag when |
|---|---|
| `listen-tcp`, `listen-udp` | `all-interfaces` on a process the user cannot name, or a remote-access tool (VNC, TeamViewer, AnyDesk, ngrok, a reverse SSH tunnel) they did not set up. Loopback listeners are low risk. A listener on a VPN or Tailscale address is reachable from that network only |
| `established` | a process with many connections that has no reason to talk to the internet, or an unsigned process with outbound connections. Cross-check the process against `procs.tsv` |
| `dns`, `dns-resolver-file` | a resolver the user, their router or their VPN did not set. Files in `/etc/resolver` route single domains; VPN and container tools add them |
| `hosts` | entries that redirect a well-known domain (bank, Apple, Google, an update server) to another address. Local-development entries are normal |
| `proxy` | any enabled proxy or PAC URL the user did not configure (adware and traffic stealers set these) |
| `vpn` | a VPN or tunnel configuration the user does not recognise |
| `trusted-cert` | any certificate with a custom trust setting the user did not add. A trusted root lets its owner read HTTPS traffic. Corporate proxies and local dev tools (mkcert, Charles, Proxyman) add them legitimately |
| `system-keychain-cert` | certificates the user or an installer put in the System keychain. Informational unless a matching `trusted-cert` row exists |

Network extensions (content filters, DNS proxies, VPN clients) are listed as `system-extension` rows in the persistence phase. `security dump-trust-settings -s` shows Apple's built-in trust list; it is not needed for this audit.

## Little Snitch

When `network.tsv` has a `little-snitch` row, its rules and connection log are worth reading. Its command-line tool needs root and "Allow access via Terminal" turned on in Little Snitch's settings. Hand the user (with the real path filled in):

```bash
sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" export-model > "$SCAN_DIR/ls-model.json"
sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" log-traffic -b "<30 days ago, YYYY-MM-DD HH:MM:SS>" > "$SCAN_DIR/ls-traffic.txt"
```

The export format is not documented here. Read its top-level keys and the shape of one rule before parsing; never print the whole file into the chat. Flag:

- allow rules for any process to any server, or for a process to any server on any port
- rules for executables that no longer exist, or that are unsigned or ad-hoc
- rules created in the last 30 days that the user does not remember approving
- in the traffic log: processes the user cannot name, connections to raw IPs from apps that normally use hostnames, and repeated denied attempts by one process (something keeps trying to phone home)

## Known false alarms

- `rapportd`, `sharingd`, `ControlCenter` (AirPlay receiver on 5000 and 7000) and `mDNSResponder` listen on all interfaces by design.
- Container runtimes (Docker, OrbStack, Colima) and local dev servers listen on all interfaces when ports are published.
