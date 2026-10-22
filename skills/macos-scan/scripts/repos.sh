#!/bin/bash
# repos.sh - code-level persistence inside your project folders: active git hooks,
# Xcode build phases that fetch or decode code, VS Code tasks that run on folder open,
# worm workflows, and project MCP configs.
# Usage: repos.sh DIR [DIR ...]      e.g. repos.sh ~/code ~/Downloads
# Read-only, no sudo. Prints paths and pattern names, never file contents.
# Rows: kind|path|detail|modified
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

[ $# -gt 0 ] || { sed -n '2,7p' "$0"; exit 1; }
T=${SCAN_TIMEOUT:-300}
PRUNE='( -name node_modules -o -name .venv -o -name venv -o -name target -o -name DerivedData -o -name .build -o -name Pods ) -prune'
echo "kind|path|detail|modified"
GIT=yes
have_git || { GIT=no; echo "skipped|git|git needs the Command Line Tools here; per-repo hooksPath not read|"; }

for root in "$@"; do
  [ -d "$root" ] || { echo "skipped|$root|not a directory|"; continue; }

  # Active git hooks (anything in .git/hooks that is not a .sample) and per-repo hooksPath.
  timeout "$T" find "$root" -maxdepth 5 $PRUNE -o -type d -name .git -print 2>/dev/null | while IFS= read -r g; do
    for h in "$g"/hooks/*; do
      [ -f "$h" ] || continue
      case "$h" in *.sample) continue ;; esac
      printf 'git-hook|%s|%s|%s\n' "$h" "$( [ -x "$h" ] && echo executable || echo not-executable )" "$(mtime "$h")"
    done
    [ "$GIT" = yes ] || continue
    hp=$(git config -f "$g/config" core.hooksPath 2>/dev/null)
    [ -n "$hp" ] && printf 'git-hooks-path|%s|%s|\n' "$g/config" "$hp"
  done
  timeout_row "${PIPESTATUS[0]}" "git repos under $root"

  # Xcode shell-script build phases that download or decode code.
  timeout "$T" find "$root" -maxdepth 6 $PRUNE -o -name project.pbxproj -print 2>/dev/null | while IFS= read -r f; do
    grep -q PBXShellScriptBuildPhase "$f" 2>/dev/null || continue
    hits=$(grep -oE 'xxd|base64|curl |wget |osascript|eval ' "$f" 2>/dev/null | sort -u | tr '\n' ',')
    [ -n "$hits" ] && printf 'xcode-build-script|%s|uses %s|%s\n' "$f" "${hits%,}" "$(mtime "$f")"
  done
  timeout_row "${PIPESTATUS[0]}" "Xcode projects under $root"

  # VS Code / Cursor tasks that start when the folder opens.
  timeout "$T" find "$root" -maxdepth 6 $PRUNE -o -name tasks.json -path '*/.vscode/*' -print 2>/dev/null | while IFS= read -r f; do
    grep -qE '"runOn"[[:space:]]*:[[:space:]]*"folderOpen"' "$f" 2>/dev/null &&
      printf 'vscode-autorun-task|%s|runOn folderOpen|%s\n' "$f" "$(mtime "$f")"
  done
  timeout_row "${PIPESTATUS[0]}" "VS Code tasks under $root"

  # Shai-Hulud style worm workflows.
  timeout "$T" find "$root" -maxdepth 6 $PRUNE -o -path '*/.github/workflows/*' -iname '*shai-hulud*' -print 2>/dev/null |
    while IFS= read -r f; do printf 'worm-workflow|%s|shai-hulud workflow name|%s\n' "$f" "$(mtime "$f")"; done
  timeout_row "${PIPESTATUS[0]}" "workflows under $root"

  # Project-level MCP configs: names only.
  timeout "$T" find "$root" -maxdepth 5 $PRUNE -o \( -name .mcp.json -o -path '*/.vscode/mcp.json' -o -path '*/.cursor/mcp.json' \) -print 2>/dev/null |
    while IFS= read -r f; do printf 'project-mcp-config|%s||%s\n' "$f" "$(mtime "$f")"; done
  timeout_row "${PIPESTATUS[0]}" "MCP configs under $root"
done
exit 0
