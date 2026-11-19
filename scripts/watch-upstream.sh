#!/bin/sh
set -u
TERMINESSD="${TERMINESSD:-$HOME/.local/bin/terminessd}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/terminess/upstream.txt"
mkdir -p "$(dirname "$STATE")"
touch "$STATE"

npm_version() { npm view "$1" version 2>/dev/null | tail -n 1; }
chrome_version() {
  curl -fsS --max-time 15 "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?pageSize=1" 2>/dev/null \
    | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1
}

changes=""
check() {   # check NAME VERSION
  name=$1; version=$2
  [ -n "$version" ] || return 0
  last=$(sed -n "s/^$name=//p" "$STATE")
  if [ "$last" != "$version" ]; then
    grep -v "^$name=" "$STATE" > "$STATE.new"; echo "$name=$version" >> "$STATE.new"; mv "$STATE.new" "$STATE"
    [ -n "$last" ] && changes="$changes $name $last to $version;"
  fi
}

check "Claude Code" "$(npm_version @anthropic-ai/claude-code)"
check "Codex" "$(npm_version @openai/codex)"
check "Gemini CLI" "$(npm_version @google/gemini-cli)"
check "Chrome DevTools MCP" "$(npm_version chrome-devtools-mcp)"
check "Chrome" "$(chrome_version)"

[ -n "$changes" ] || { echo "no new releases"; exit 0; }
changes=${changes# }
result=$("$TERMINESSD" tools check 2>&1)
if printf '%s\n' "$result" | grep -q '^problem:'; then verdict="the Terminess check found a problem"
elif printf '%s\n' "$result" | grep -q '^ok:'; then verdict="the Terminess check passed"
else verdict="the Terminess check couldn't run"; fi
echo "new: $changes ($verdict)"
"$TERMINESSD" remind add --at +1m --title "New release: ${changes%;} ($verdict)" \
  --action-prompt "New releases of tools Terminess works with: ${changes%;}. terminessd tools check said: $(printf '%s' "$result" | tr '\n' ' '). Read each one's release notes and say plainly whether anything Terminess relies on changed (CLI flags, config keys, hooks, transcript formats, MCP options) and what to do. Don't change anything."
