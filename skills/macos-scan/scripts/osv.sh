#!/bin/bash
# osv.sh - match installed packages and lockfiles against OSV (CVEs plus the OpenSSF
# malicious-packages list) with osv-scanner, using offline databases.
# Usage: osv.sh fetch                          download the pinned osv-scanner; refuse it unless its
#                                              SHA-256 matches the value pinned in this script
#        osv.sh scan-installed OUT.json [DIR...] installed packages (dirs from packages.sh scan-dirs;
#                                              with no DIR, one directory per line on stdin)
#        osv.sh scan-lockfiles OUT.json [DIR...] lockfiles under code folders (honours .gitignore)
#        osv.sh summarize OUT.json [...]       malicious first, then critical, then high
#                                              (UNSCORED=1 also lists advisories with no score)
# Env:   OSV_HOME  holds the binary and databases (default: $TMPDIR/macos-scan-osv)
# Network: fetch needs github.com. A scan downloads databases from
# osv-vulnerabilities.storage.googleapis.com. Scans run with --no-resolve and Go/Rust call
# analysis off, so nothing should reach api.deps.dev or proxy.golang.org; still run them
# under a network allowlist that permits only the storage host, so the inventory never
# leaves the machine. Every scan includes a canary lockfile with a known-vulnerable
# package; summarize fails loudly if the canary comes back clean.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$HERE/lib.sh"
usage_if_help "$@"

# Pinned release and its SHA-256s, copied from the release's osv-scanner_SHA256SUMS when
# the pin was set. When bumping, pick a release at least two weeks old and update all three.
VERSION=v2.6.0
SHA256_arm64=98c460dcd37de25819babd757d04542045b6243113e209edcd4d89fedb0256b4
SHA256_amd64=60c5296637e977b28eeda5c7f13573e447659a632922737f94d11fa7e30ad6ca
OSV_HOME=${OSV_HOME:-${TMPDIR:-/tmp}/macos-scan-osv}
BIN="$OSV_HOME/osv-scanner"
export OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$OSV_HOME/db"

usage() { sed -n '2,10p' "$0"; exit 1; }

fetch() {
  local arch asset want got
  arch=$(uname -m); [ "$arch" = x86_64 ] && arch=amd64
  asset="osv-scanner_darwin_$arch"
  case "$arch" in arm64) want=$SHA256_arm64 ;; amd64) want=$SHA256_amd64 ;; *) echo "unsupported arch $arch" >&2; return 1 ;; esac
  mkdir -p "$OSV_HOME"
  curl -fsSL -o "$OSV_HOME/$asset" "https://github.com/google/osv-scanner/releases/download/$VERSION/$asset" || return 1
  got=$(shasum -a 256 "$OSV_HOME/$asset" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for $asset: got $got, pinned $want. Not using it." >&2
    rm -f "$OSV_HOME/$asset"
    return 1
  fi
  mv "$OSV_HOME/$asset" "$BIN" && chmod +x "$BIN"
  "$BIN" --version | head -1
}

canary() {
  local c="$OSV_HOME/canary"
  mkdir -p "$c"
  # lodash 4.17.4 has several published advisories (prototype pollution, ReDoS).
  cat > "$c/package-lock.json" <<'JSON'
{"name":"macos-scan-canary","lockfileVersion":3,"requires":true,"packages":{"":{"name":"macos-scan-canary","dependencies":{"lodash":"4.17.4"}},"node_modules/lodash":{"version":"4.17.4"}}}
JSON
  printf '%s\n' "$c"
}

scan() {
  local out="$1" plugins="$2"; shift 2
  [ -x "$BIN" ] || { echo "run: $0 fetch" >&2; return 1; }
  # No directories on the command line: read them from stdin, one per line, so paths
  # with spaces survive (osv.sh scan-installed out.json < scan-dirs.txt).
  if [ $# -eq 0 ] && [ ! -t 0 ]; then
    while IFS= read -r d; do [ -n "$d" ] && set -- "$@" "$d"; done
  fi
  [ $# -gt 0 ] || usage
  # --offline-vulnerabilities with --download-offline-databases on every run: the download
  # only covers ecosystems seen in that run, and a missing database silently yields no results.
  set -- "$@" "$(canary)"
  # --no-resolve stops transitive resolution of manifests, which would send package
  # names to api.deps.dev; call analysis would fetch Go modules.
  "$BIN" scan source --offline-vulnerabilities --download-offline-databases --no-resolve \
    --no-call-analysis go --no-call-analysis rust \
    $plugins --all-packages --format json --output-file "$out" -r "$@" 2> "$out.log"
  local rc=$?
  if grep -q 'unable to fetch OSV database' "$out.log"; then
    echo "WARNING: a database was missing; results are incomplete. See $out.log" >&2
  fi
  grep -c 'failed resolution' "$out.log" | awk '$1>0 {print "note: "$1" requirements files could not be resolved offline (not scanned)"}' >&2
  # osv-scanner exits 1 when it finds vulnerabilities; that is success here.
  [ "$rc" -le 1 ]
}

summarize() {
  local py
  py=$(py)
  [ -n "$py" ] || { echo "python3 needed" >&2; return 1; }
  CANARY_DIR="$OSV_HOME/canary/" "$py" -I - "$@" <<'PYEOF'
import json, os, sys
canary_dir = os.path.realpath(os.environ["CANARY_DIR"]) + "/"
list_unscored = os.environ.get("UNSCORED") == "1"
rows, canary_hits, scanned, unscored = [], 0, 0, 0
for f in sys.argv[1:]:
    d = json.load(open(f))
    for r in d.get("results", []):
        src = r["source"]["path"]
        for p in r.get("packages", []):
            scanned += 1
            pk = p["package"]
            vulns = p.get("vulnerabilities") or []
            if os.path.realpath(src).startswith(canary_dir):
                canary_hits += len(vulns)
                continue
            sev = {}
            for g in p.get("groups") or []:
                for i in g.get("ids", []):
                    sev[i] = g.get("max_severity") or ""
            for v in vulns:
                vid = v["id"]
                s = sev.get(vid, "")
                try:
                    score = float(s)
                except ValueError:
                    score = -1.0
                if vid.startswith("MAL-"):
                    cls = "malicious"
                elif score >= 9:
                    cls = "critical"
                elif score >= 7:
                    cls = "high"
                elif score < 0:
                    unscored += 1   # no CVSS score published: counted, listed with UNSCORED=1
                    if not list_unscored:
                        continue
                    cls = "unscored"
                else:
                    continue
                fixed = ""
                for a in v.get("affected", []):
                    for rg in a.get("ranges", []):
                        for e in rg.get("events", []):
                            if "fixed" in e:
                                fixed = e["fixed"]
                rows.append((("malicious", "critical", "high", "unscored").index(cls), cls, vid, pk.get("ecosystem", ""),
                             pk["name"], pk.get("version", ""), fixed, s, src))
print("class|id|ecosystem|package|version|fixed_in|severity|source")
for r in sorted(set(rows)):
    print("|".join(str(x) for x in r[1:]))
print("summary|packages scanned=%d|unscored advisories=%d|canary vulns=%d|%s" % (scanned, unscored, canary_hits,
      "OK" if canary_hits else "BROKEN: canary came back clean, so the database or matcher failed"), file=sys.stderr)
sys.exit(0 if canary_hits else 2)
PYEOF
}

case "${1:-}" in
  fetch) fetch ;;
  scan-installed) shift; out="${1:-}"; [ -n "$out" ] || usage; shift
                  scan "$out" "--experimental-plugins artifact --experimental-plugins lockfile" "$@" ;;
  scan-lockfiles) shift; out="${1:-}"; [ -n "$out" ] || usage; shift
                  scan "$out" "--experimental-plugins lockfile" "$@" ;;
  summarize) shift; [ $# -gt 0 ] || usage; summarize "$@" ;;
  *) usage ;;
esac
