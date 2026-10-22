#!/bin/bash
# packages.sh - what every package manager has installed, with versions, plus the
# directories osv-scanner should scan for installed packages.
# Usage: packages.sh inventory        rows: manager|name|version|location
#        packages.sh scan-dirs        one directory per line, for osv.sh scan-installed
# Read-only, no sudo, no network: brew runs with HOMEBREW_NO_AUTO_UPDATE, so "outdated"
# compares against the formula data from the last `brew update`.
set -u
[ -n "${MACOS_SCAN_LIB:-}" ] || . "$(dirname "$0")/lib.sh"
usage_if_help "$@"

# missing TOOL -> a row saying the manager is not installed, so absence is never silent
missing() { printf 'skipped|%s|not installed or not on PATH|\n' "$1"; }

inventory() {
  echo "manager|name|version|location"
  have brew || missing brew
  if have brew; then
    brew list --formula --versions 2>/dev/null | awk '{print "brew-formula|"$1"|"$NF"|"}'
    brew list --cask --versions 2>/dev/null | awk '{print "brew-cask|"$1"|"$NF"|"}'
    brew outdated --greedy --verbose 2>/dev/null | sed -n 's/^\([^ ]*\) (\(.*\)) [<!=]* \(.*\)$/brew-outdated|\1|\2 -> \3|/p'
    brew tap 2>/dev/null | awk '{print "brew-tap|"$1"||"}'
  fi
  # npm globals for every installed Node (version managers keep one tree per version).
  npm_roots | while IFS= read -r nm; do
    for p in "$nm"/* "$nm"/@*/*; do
      [ -f "$p/package.json" ] || continue
      v=$(sed -n 's/^  "version": "\(.*\)",*$/\1/p' "$p/package.json" | head -1)
      printf 'npm-global|%s|%s|%s\n' "${p#"$nm"/}" "$v" "$nm"
    done
  done
  if [ -f "$HOME/.bun/install/global/package.json" ]; then
    sed -n 's/^    "\([^"]*\)": "\(.*\)",*$/bun-global|\1|\2|~\/.bun\/install\/global/p' "$HOME/.bun/install/global/package.json"
  fi
  have pnpm || missing pnpm
  have pnpm && pnpm ls -g --depth=0 --parseable --long 2>/dev/null | awk -F: 'NF>=2 {print "pnpm-global|"$2"||"$1}'
  have pipx || missing pipx
  have pipx && pipx list --short 2>/dev/null | awk '{print "pipx|"$1"|"$2"|"}'
  have uv || missing uv
  have uv && uv tool list 2>/dev/null | awk '/^[^- ]/ {sub(/^v/, "", $2); print "uv-tool|"$1"|"$2"|"}'
  if [ -f "$HOME/.cargo/.crates2.json" ]; then
    grep -oE '"[a-zA-Z0-9_-]+ [0-9][^ ]* \([^)]*\)"' "$HOME/.cargo/.crates2.json" | tr -d '"' |
      awk '{print "cargo|"$1"|"$2"|"$3}'
  fi
  have go || missing go
  if have go; then
    gobin=$(go env GOBIN 2>/dev/null); [ -n "$gobin" ] || gobin="$(go env GOPATH 2>/dev/null)/bin"
    for b in "$gobin"/*; do
      [ -x "$b" ] || continue
      go version -m "$b" 2>/dev/null | awk -v b="$b" '$1=="mod" {print "go-binary|"$2"|"$3"|"b}'
    done
  fi
  # Homebrew Ruby's gems and the system Ruby's gems are separate sets; list both.
  for g in /opt/homebrew/opt/ruby/bin/gem /usr/local/opt/ruby/bin/gem /usr/bin/gem; do
    [ -x "$g" ] && "$g" list --local 2>/dev/null |
      awk -v g="$g" '/^[^ ]+ \(.*\)$/ { v=$0; sub(/^[^ ]+ \(/, "", v); sub(/\)$/, "", v); print "gem|"$1"|"v"|"g }'
  done
  have mas && mas list 2>/dev/null | awk '{id=$1; $1=""; v=$NF; $NF=""; gsub(/^ +| +$/, ""); print "app-store|"$0"|"v"|id "id}'
  return 0
}

# Global npm roots from Homebrew Node, fnm, nvm, volta and asdf.
npm_roots() {
  for d in /opt/homebrew/lib/node_modules /usr/local/lib/node_modules \
           "$HOME"/.fnm/node-versions/*/installation/lib/node_modules \
           "$HOME"/Library/Application\ Support/fnm/node-versions/*/installation/lib/node_modules \
           "$HOME"/.nvm/versions/node/*/lib/node_modules \
           "$HOME"/.volta/tools/image/node/*/lib/node_modules \
           "$HOME"/.asdf/installs/nodejs/*/lib/node_modules; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# Directories that hold installed packages osv-scanner can read with its artifact
# plugins: node_modules trees, Python environments, Go and Rust binaries.
scan_dirs() {
  npm_roots
  for d in "$HOME/.bun/install/global" "$HOME/.local/pipx/venvs" "$HOME/.local/share/pipx/venvs" \
           "$HOME/.local/share/uv/tools" "$HOME/.cargo/bin" "$HOME/go/bin" "$HOME/.local/bin" \
           /opt/homebrew/bin; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

case "${1:-}" in
  inventory) inventory ;;
  scan-dirs) scan_dirs ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
