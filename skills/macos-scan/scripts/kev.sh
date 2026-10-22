#!/bin/bash
# kev.sh - match installed apps against CISA's Known Exploited Vulnerabilities catalog.
# Usage: kev.sh fetch OUT.json             download the catalog (public, no inventory sent)
#        kev.sh match KEV.json APPS.tsv    APPS.tsv is the output of apps.sh
# Rows: lead|app|version|signer|kev_vendor|kev_product|newest_cves|count|latest_date_added
#
# Output is LEADS ONLY. KEV entries carry no version ranges, so a row means "this vendor
# and product had an exploited bug at some point", never "this Mac is vulnerable".
# A row needs the KEV vendor to match the app's code-signing organisation or bundle-id
# vendor AND every distinctive KEV product word to appear in the app's name or bundle id.
# Plain name matching produced junk (an Apple MIDI utility matched a VPN appliance).
# Confirm each lead by comparing the installed version with the vendor advisory.
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

URL=https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json

case "${1:-}" in
  fetch)
    [ -n "${2:-}" ] || { sed -n '2,4p' "$0"; exit 1; }
    curl -fsSL -o "$2" "$URL" && echo "saved $2 ($(grep -o '"cveID"' "$2" | wc -l | tr -d ' ') entries)" ;;
  match)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { sed -n '2,4p' "$0"; exit 1; }
    PY=$(py); [ -n "$PY" ] || { echo "python3 needed" >&2; exit 1; }
    "$PY" -I - "$2" "$3" <<'PYEOF'
import json, re, sys
kev = json.load(open(sys.argv[1]))["vulnerabilities"]
GENERIC = {"client", "server", "app", "application", "desktop", "for", "mac", "macos", "os", "x", "the",
           "and", "of", "suite", "pro", "edition", "software", "multiple", "products", "framework"}
def toks(s):
    return set(re.findall(r"[a-z0-9]+", (s or "").lower()))
def org(signer):
    # "Developer ID Application: Google LLC (EQHXZ8M8AV)" -> "google llc"
    m = re.match(r"(?:Developer ID Application|Apple Distribution|Apple Development): (.*?) \(", signer or "")
    if m:
        return m.group(1)
    if signer in ("Software Signing", "Apple Mac OS Application Signing"):
        return "apple"
    return ""
# Products that cannot be a Mac app: Windows components share the vendor with Mac apps.
NOT_MAC = {"windows", "win32k", "exchange", "sharepoint", "iis", "hyper"}
leads = {}
for line in open(sys.argv[2]):
    f = line.rstrip("\n").split("|")
    if len(f) < 7 or f[0] == "kb":
        continue
    path, bid, ver, signer = f[1], f[2], f[3], f[4]
    if "/Chrome Apps.localized/" in path:   # web-app shims, not separate software
        continue
    name = path.rsplit("/", 1)[-1][:-4]
    # The signing organisation names the vendor. Only App Store and Apple-signed apps
    # fall back to the bundle id, whose second part is often a product or a person
    # (ch.sudo.cyberduck would otherwise match the vendor "Sudo").
    o = org(signer)
    vendor_toks = toks(o) - GENERIC
    if o in ("", "apple"):
        parts = bid.split(".")
        vendor_toks = {parts[1].lower()} if len(parts) >= 2 else set()
    app_toks = toks(name) | toks(bid)
    for k in kev:
        vt = toks(k["vendorProject"]) - GENERIC
        if not vt or not (vt & vendor_toks):
            continue
        pt = toks(k["product"]) - GENERIC - vt   # "Microsoft Office" -> {"office"}
        if not pt or not pt <= app_toks or pt & NOT_MAC:
            continue
        key = (name, ver, signer, k["vendorProject"], k["product"])
        leads.setdefault(key, []).append((k["dateAdded"], k["cveID"]))
print("lead|app|version|signer|kev_vendor|kev_product|newest_cves|count|latest_date_added")
for key, cves in sorted(leads.items()):
    cves.sort(reverse=True)
    print("|".join(["lead"] + list(key) + [",".join(c for _, c in cves[:5]), str(len(cves)), cves[0][0]]))
PYEOF
    ;;
  *) sed -n '2,4p' "$0"; exit 1 ;;
esac
