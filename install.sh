#!/bin/bash
set -euo pipefail

DMG_URL="${TERMINESS_DMG_URL:-https://terminess.com/downloads/Terminess.dmg}"
TEAM_ID="3Y5DXCU484"

say() { printf '\033[38;5;214m==>\033[0m %s\n' "$*"; }
fail() { printf 'terminess: %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  fail "this installs the Mac app. For a Linux PC or server, build terminessd: https://github.com/Terminess/terminess#install"
fi
version="$(sw_vers -productVersion)"
[ "${version%%.*}" -ge 14 ] || fail "Terminess needs macOS 14 or later; this Mac has $version."

tmp="$(mktemp -d)"
mnt="$tmp/mnt"
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

say "Downloading Terminess"
curl -fL --progress-bar "$DMG_URL" -o "$tmp/Terminess.dmg"

mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$tmp/Terminess.dmg"
app="$mnt/Terminess.app"
[ -d "$app" ] || fail "the download doesn't contain Terminess.app"

say "Checking the signature"
codesign --verify --deep --strict "$app" 2>/dev/null || fail "the app's signature is invalid"
signer="$(codesign -dv "$app" 2>&1 || true)"
case "$signer" in *"TeamIdentifier=$TEAM_ID"*) ;; *) fail "the app isn't signed by the Terminess developer" ;; esac
spctl --assess --type execute "$app" 2>/dev/null || fail "Gatekeeper didn't approve the app"

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

if pgrep -xq Terminess; then
  say "Quitting Terminess (your sessions keep running)"
  osascript -e 'quit app "Terminess"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq Terminess || break; sleep 0.5; done
  pgrep -xq Terminess && fail "Terminess is still running; quit it and run this again."
fi

say "Installing to $dest"
rm -rf "$dest/Terminess.app"
ditto "$app" "$dest/Terminess.app"

say "Opening Terminess"
open "$dest/Terminess.app"
echo
echo "Installed. To pair your iPhone, choose Terminess, Pair iPhone in the menu bar."
