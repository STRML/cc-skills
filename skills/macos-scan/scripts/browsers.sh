#!/bin/bash
# browsers.sh - browser extensions in every profile, forced policies, native messaging hosts.
# Usage: browsers.sh
# Read-only, no sudo. Needs python3 (Homebrew or Command Line Tools) for the JSON files.
# Rows: kind|browser|profile|id|name|version|modified|source|risky-permissions
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

PY=$(py)
AS="$HOME/Library/Application Support"
echo "kind|browser|profile|id|name|version|modified|source|risky-permissions"
if [ -z "$PY" ]; then
  echo "skipped|chromium-family|||python3 not available||||"
else
  OUT=$(mktemp -t macos-scan-browsers)
  trap 'rm -f "$OUT"' EXIT
  "$PY" -I - "$AS" > "$OUT" <<'PYEOF'
import json, os, re, sys, glob, time
AS = sys.argv[1]
BROWSERS = {
    "Chrome": "Google/Chrome", "Chrome Beta": "Google/Chrome Beta", "Chrome Canary": "Google/Chrome Canary",
    "Arc": "Arc/User Data", "Brave": "BraveSoftware/Brave-Browser", "Edge": "Microsoft Edge",
    "Chromium": "Chromium", "Vivaldi": "Vivaldi", "Opera": "com.operasoftware.Opera",
    "Comet": "Comet", "Dia": "Dia/User Data", "Helium": "net.imput.helium",
}
RISKY = {"<all_urls>", "*://*/*", "http://*/*", "https://*/*", "nativeMessaging", "debugger", "proxy",
         "webRequest", "webRequestBlocking", "cookies", "management", "scripting", "clipboardRead",
         "history", "tabCapture", "desktopCapture", "privacy", "declarativeNetRequestWithHostAccess"}
# Chromium's Extension::Location enum, as stored in Preferences.
LOCATION = {1: "webstore-or-user", 2: "external-pref", 4: "unpacked-sideload", 5: "component",
            6: "external-pref-download", 7: "policy-forced", 8: "command-line", 9: "policy-forced",
            10: "external-component"}

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}

def msg(ext_dir, value, default_locale):
    if not isinstance(value, str) or not value.startswith("__MSG_"):
        return value
    key = value[6:-2].lower()
    for loc in [default_locale or "en", "en", "en_US"]:
        d = load(os.path.join(ext_dir, "_locales", loc, "messages.json"))
        for k, v in d.items():
            if k.lower() == key:
                return v.get("message", value)
    return value

def clean(s):
    return str(s).replace("|", "/").replace("\n", " ")

def denied(browser, where, err):
    print("|".join(clean(x) for x in ["denied", browser, where, "", type(err).__name__, "", "", "", ""]))

def listdir(path):
    try:
        return os.listdir(path)
    except OSError as e:
        return e

def vkey(v):
    # "10.0_0" must sort after "9.0_0": compare version parts as numbers.
    return [int(x) if x.isdigit() else -1 for x in re.split(r"[._-]", v)]

for browser, rel in BROWSERS.items():
    base = os.path.join(AS, rel)
    if not os.path.exists(base):
        continue
    entries = listdir(base)
    if isinstance(entries, OSError):
        denied(browser, base, entries)   # profile folder protected or unreadable
        continue
    profiles = []
    for e in entries:
        p = os.path.join(base, e)
        if not os.path.isdir(p):
            continue
        inner = listdir(p)
        if isinstance(inner, OSError):
            denied(browser, p, inner)
        elif "Extensions" in inner:
            profiles.append(p)
    if "Extensions" in entries:
        profiles.append(base)
    for prof in sorted(profiles):
        settings = {}
        for f in ("Secure Preferences", "Preferences"):
            settings.update(load(os.path.join(prof, f)).get("extensions", {}).get("settings", {}))
        ext_ids = listdir(os.path.join(prof, "Extensions"))
        if isinstance(ext_ids, OSError):
            denied(browser, os.path.join(prof, "Extensions"), ext_ids)
            continue
        for ext_id in sorted(ext_ids):
            try:
                root = os.path.join(prof, "Extensions", ext_id)
                if not os.path.isdir(root) or ext_id == "Temp":
                    continue
                versions = sorted(os.listdir(root), key=vkey)
                if not versions:
                    continue
                vdir = os.path.join(root, versions[-1])
                m = load(os.path.join(vdir, "manifest.json"))
                name = msg(vdir, m.get("name", "?"), m.get("default_locale"))
                perms = [p for p in m.get("permissions", []) + m.get("host_permissions", []) if isinstance(p, str)]
                for cs in m.get("content_scripts", []):
                    perms += [x for x in cs.get("matches", []) if x in RISKY]
                risky = sorted(set(p for p in perms if p in RISKY))
                st = settings.get(ext_id, {})
                src = LOCATION.get(st.get("location"), "unknown")
                if st.get("from_webstore") is False and src == "webstore-or-user":
                    src = "not-from-webstore"
                mod = time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(root)))
                print("|".join(clean(x) for x in ["extension", browser, os.path.basename(prof), ext_id, name,
                      m.get("version", "?"), mod, src, ",".join(risky)]))
            except OSError as e:
                denied(browser, os.path.join(prof, "Extensions", ext_id), e)

# Firefox: everything not shipped with the browser.
ff = os.path.join(AS, "Firefox", "Profiles")
if os.path.exists(ff) and isinstance(listdir(ff), OSError):
    denied("Firefox", ff, listdir(ff))
for prof in glob.glob(os.path.join(ff, "*")):
    for a in load(os.path.join(prof, "extensions.json")).get("addons", []):
        if str(a.get("location", "")).startswith("app-"):
            continue
        name = (a.get("defaultLocale") or {}).get("name", "?")
        perms = (a.get("userPermissions") or {}).get("permissions", []) + (a.get("userPermissions") or {}).get("origins", [])
        risky = sorted(set(p for p in perms if p in RISKY))
        print("|".join(clean(x) for x in ["extension", "Firefox", os.path.basename(prof), a.get("id"), name,
              a.get("version"), "", "%s signed=%s active=%s" % (a.get("location"), a.get("signedState"), a.get("active")),
              ",".join(risky)]))

# Native messaging hosts: a JSON file that lets an extension launch a local binary.
dirs = glob.glob(os.path.join(AS, "*", "NativeMessagingHosts")) + glob.glob(os.path.join(AS, "*", "*", "NativeMessagingHosts")) \
     + glob.glob("/Library/Google/Chrome/NativeMessagingHosts") + glob.glob("/Library/Application Support/*/NativeMessagingHosts") \
     + glob.glob(os.path.join(AS, "Mozilla", "NativeMessagingHosts"))
for d in sorted(set(dirs)):
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        target = load(f).get("path", "")
        print("|".join(clean(x) for x in ["native-host", os.path.relpath(d, AS) if d.startswith(AS) else d, "",
              os.path.basename(f)[:-5], target, "", time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(f))), "", ""]))
PYEOF
  # Native messaging host rows carry the target binary in the name column; add its signer.
  while IFS= read -r line; do
    case "$line" in
      native-host\|*)
        target=$(printf '%s' "$line" | cut -d'|' -f5)
        signer=$(sig "$target" | cut -d'|' -f1)
        printf '%s\n' "$line" | awk -F'|' -v OFS='|' -v s="$signer" '{$8=s; print}' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$OUT"
fi

# Safari extensions come from app bundles and register with pluginkit.
for proto in com.apple.Safari.web-extension com.apple.Safari.extension com.apple.Safari.content-blocker; do
  pluginkit -mAv -p "$proto" 2>/dev/null | awk -F'\t' -v p="$proto" 'NF>=2 {
    id=$1; st=(id ~ /^ *-/) ? "disabled" : "enabled"; gsub(/^[ +\-!=]+/, "", id);
    print "extension|Safari||"id"|"$NF"||"  "|"st" "p"|"}'
done

# Policies that can force-install extensions, set a proxy or a homepage.
for d in "/Library/Managed Preferences" "/Library/Managed Preferences/$(id -un)"; do
  for f in "$d"/*.plist; do
    [ -e "$f" ] || continue
    keys=$(plutil -p "$f" 2>/dev/null | grep -oE '"(ExtensionInstallForcelist|ExtensionInstallSources|ExtensionSettings|ProxySettings|ProxyMode|ProxyServer|HomepageLocation|RestoreOnStartupURLs|DefaultSearchProviderSearchURL|DnsOverHttpsTemplates)"' | tr -d '"' | sort -u | tr '\n' ',')
    printf 'policy|%s|%s|||||%s|%s\n' "$(basename "$f" .plist)" "$d" "$(mtime "$f")" "${keys%,}"
  done
done
for dom in com.google.Chrome company.thebrowser.Browser com.brave.Browser com.microsoft.Edge org.chromium.Chromium org.mozilla.firefox; do
  for f in "/Library/Preferences/$dom.plist" "$HOME/Library/Preferences/$dom.plist"; do
    [ -e "$f" ] || continue
    keys=$(plutil -p "$f" 2>/dev/null | grep -oE '"(ExtensionInstallForcelist|ExtensionInstallSources|ExtensionSettings|ProxySettings|ProxyMode|ProxyServer|HomepageLocation|RestoreOnStartupURLs|DefaultSearchProviderSearchURL|DnsOverHttpsTemplates)"' | tr -d '"' | sort -u | tr '\n' ',')
    [ -n "$keys" ] && printf 'policy|%s|%s|||||%s|%s\n' "$dom" "$f" "$(mtime "$f")" "${keys%,}"
  done
done
[ -e /Applications/Firefox.app/Contents/Resources/distribution/policies.json ] &&
  echo "policy|Firefox|/Applications/Firefox.app/Contents/Resources/distribution/policies.json||||||present"
exit 0
