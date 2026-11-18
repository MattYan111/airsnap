#!/bin/zsh
# One-command source installer for AirSnap (avoids macOS Gatekeeper quarantine).
set -e

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Starting installer..."
  xcode-select --install || true
  echo "Finish installing Xcode Command Line Tools, then re-run this script."
  exit 1
fi

SCRIPT_DIR=""
if [ -n "${0:A}" ] && [ -f "${0:A:h}/main.swift" ] && [ -f "${0:A:h}/build.sh" ]; then
  SCRIPT_DIR="${0:A:h}"
fi

if [ -n "$SCRIPT_DIR" ]; then
  cd "$SCRIPT_DIR"
  chmod +x ./build.sh
  ./build.sh
else
  REPO_URL="${AIRSNAP_REPO:-https://github.com/MattYan111/airsnap.git}"
  TMP_DIR=$(mktemp -d /tmp/airsnap-install-XXXXXX)
  trap 'rm -rf "$TMP_DIR"' EXIT
  echo "Cloning AirSnap from $REPO_URL ..."
  git clone --depth 1 "$REPO_URL" "$TMP_DIR/airsnap"
  cd "$TMP_DIR/airsnap"
  chmod +x ./build.sh
  ./build.sh
fi

echo "Launching AirSnap..."
if [ -d "/Applications/AirSnap.app" ]; then
  open -a "/Applications/AirSnap.app"
elif [ -d "$HOME/Applications/AirSnap.app" ]; then
  open -a "$HOME/Applications/AirSnap.app"
fi

echo "Done! Look for the camera icon in your menu bar (default shortcut: ⌥⌘C)."
