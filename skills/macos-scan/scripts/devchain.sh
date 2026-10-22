#!/bin/bash
# devchain.sh - developer tooling that runs code on your behalf: editor extensions,
# MCP servers, agent hooks, third-party Homebrew taps, global git hooks.
# Usage: devchain.sh
# Read-only, no sudo. Prints server names and the program they launch, never
# their arguments or environment (those often carry tokens).
# Rows: kind|source|name|detail|modified
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

PY=$(py)
echo "kind|source|name|detail|modified"

for d in "$HOME/.vscode/extensions" "$HOME/.vscode-insiders/extensions" "$HOME/.cursor/extensions" \
         "$HOME/.windsurf/extensions" "$HOME/.vscode-oss/extensions" "$HOME/.positron/extensions" \
         "$HOME/Library/Application Support/Zed/extensions/installed"; do
  [ -d "$d" ] || continue
  for e in "$d"/*; do
    [ -d "$e" ] || continue
    printf 'editor-extension|%s|%s||%s\n' "$d" "$(basename "$e")" "$(mtime "$e")"
  done
done

# MCP servers and agent hooks. Names and the launched program only.
if [ -n "$PY" ]; then
  "$PY" -I - "$HOME" <<'PYEOF'
import json, os, sys, time, re, shlex
H = sys.argv[1]
def load(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None
def mod(p):
    return time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(p)))
def clean_url(u):
    # user:password@ and query strings both carry credentials
    u = re.sub(r"(//)[^/@\s]*@", r"\1", str(u))
    return re.sub(r"[?#].*$", "", u)
def first_cmd(raw):
    # The program a command string runs: leading KEY=value assignments are skipped
    # (they are where tokens live) and noted, arguments are dropped. A value that is an
    # existing path is one program even when it contains spaces.
    if os.path.exists(os.path.expanduser(str(raw))):
        return str(raw), []
    try:
        tok = shlex.split(str(raw))
    except ValueError:
        tok = str(raw).split()
    env = 0
    while tok and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok[0]):
        tok.pop(0)
        env += 1
    if not tok:
        return "?", []
    return clean_url(tok[0]) + (" (+%d env)" % env if env else ""), tok[1:]
def prog(cfg):
    if not isinstance(cfg, dict):
        return "?"
    if cfg.get("url"):
        return "remote " + clean_url(cfg["url"])
    cmd, extra = first_cmd(cfg.get("command", "?"))
    args = (cfg.get("args") or []) or extra
    # Package runners name what they fetch in an argument; show that package.
    runner = os.path.basename(cmd.split(" (+")[0])
    if runner in ("npx", "uvx", "bunx", "pnpm", "pipx", "docker", "uv") and args:
        args = [str(a) for a in args]
        pkg_flags = ("--from", "--package") + (("-p",) if runner == "npx" else ())
        for flag in pkg_flags:
            if flag in args[:-1]:
                return "%s %s" % (cmd, clean_url(args[args.index(flag) + 1]))
        takes_value = {"--python", "--with", "--index", "--index-url", "-e", "--env", "--name"}
        skip = False
        for a in args:
            if skip:
                skip = False
                continue
            if a in takes_value:
                skip = True
                continue
            if not a.startswith("-") and a not in ("run", "tool", "dlx", "exec"):
                return "%s %s" % (cmd, clean_url(a))
    return cmd
JSON_FILES = [
    (".claude.json", ["mcpServers"]),
    (".cursor/mcp.json", ["mcpServers"]),
    (".codeium/windsurf/mcp_config.json", ["mcpServers"]),
    ("Library/Application Support/Claude/claude_desktop_config.json", ["mcpServers"]),
    ("Library/Application Support/Code/User/mcp.json", ["servers"]),
    ("Library/Application Support/Code/User/settings.json", ["mcp", "servers"]),
    (".gemini/settings.json", ["mcpServers"]),
]
for rel, path in JSON_FILES:
    p = os.path.join(H, rel)
    d = load(p) if os.path.exists(p) else None
    if not isinstance(d, dict):
        continue
    blocks = []
    cur = d
    for k in path:
        cur = cur.get(k, {}) if isinstance(cur, dict) else {}
    blocks.append(("global", cur))
    for proj, pd in (d.get("projects") or {}).items():
        if isinstance(pd, dict):
            blocks.append((proj, pd.get("mcpServers") or {}))
    for scope, servers in blocks:
        if not isinstance(servers, dict):
            continue
        for name, cfg in servers.items():
            print("mcp-server|%s [%s]|%s|%s|%s" % (rel, scope, name, prog(cfg), mod(p)))
# Codex keeps MCP servers in TOML.
p = os.path.join(H, ".codex/config.toml")
if os.path.exists(p):
    name = None
    for line in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*\[mcp_servers\.([^.\]]+)\]\s*$", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r'\s*command\s*=\s*"([^"]*)"', line)
        if name and m:
            print("mcp-server|.codex/config.toml|%s|%s|%s" % (name, first_cmd(m.group(1))[0], mod(p)))
            name = None
# Agent hooks run shell commands on tool events.
SEEN = set()
for rel in (".claude/settings.json", ".claude/settings.local.json", ".codex/hooks.json", ".gemini/settings.json"):
    p = os.path.join(H, rel)
    d = load(p) if os.path.exists(p) else None
    if not isinstance(d, dict):
        continue
    for event, entries in (d.get("hooks") or {}).items():
        for entry in entries if isinstance(entries, list) else []:
            for h in (entry.get("hooks") or [entry]) if isinstance(entry, dict) else []:
                raw = str(h.get("command", "")).strip() if isinstance(h, dict) else ""
                cmd, rest = first_cmd(raw)
                if cmd == "?":
                    continue
                if os.path.basename(cmd.split(" ")[0]) in ("sh", "bash", "zsh", "python3", "python", "node", "bun", "uv") and rest:
                    cmd = cmd + (" -c (inline)" if rest[0] == "-c" else " " + clean_url(rest[0]))
                seen = (rel, event, cmd)
                if seen in SEEN:
                    continue
                SEEN.add(seen)
                print("agent-hook|%s|%s|%s|%s" % (rel, event, cmd, mod(p)))
PYEOF
else
  echo "skipped|mcp-and-hooks|python3 not available||"
fi

if have brew; then
  brew tap 2>/dev/null | while read -r t; do
    case "$t" in homebrew/*) kind=brew-tap-official ;; *) kind=brew-tap-third-party ;; esac
    printf '%s|brew|%s||\n' "$kind" "$t"
  done
fi

# GitHub Actions self-hosted runners: code from the repo's workflows runs on this Mac.
for r in "$HOME"/actions-runner* "$HOME"/*/actions-runner* "$HOME"/*/*/actions-runner*; do
  [ -f "$r/.runner" ] || continue
  url=$(tr -d '\000\357\273\277' < "$r/.runner" | sed -n 's/.*"gitHubUrl": *"\([^"]*\)".*/\1/p' | head -1)
  printf 'self-hosted-runner|%s|%s||%s\n' "$r" "${url:-unknown}" "$(mtime "$r/.runner")"
done

if have_git; then
  for k in core.hooksPath init.templateDir core.fsmonitor core.sshCommand credential.helper include.path; do
    git config --global --get-all "$k" 2>/dev/null | while read -r v; do
      # sshCommand and credential.helper can embed key paths, tokens or inline scripts:
      # show a plain helper name, otherwise only that the key is set.
      case "$k" in
        core.sshCommand|credential.helper)
          printf '%s' "$v" | grep -qE '^[A-Za-z0-9._-]+$' || v="set (value hidden)" ;;
      esac
      printf 'git-global|~/.gitconfig|%s|%s|\n' "$k" "$v"
    done
  done
else
  echo "skipped|git|git needs the Command Line Tools here; global git settings not read||"
fi
exit 0
