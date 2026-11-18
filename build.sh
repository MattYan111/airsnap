#!/bin/zsh
# Build AirSnap.app (universal, pure offline, locally signed)
# and install it to /Applications (or ~/Applications if locked down).
set -e
cd "$(dirname "$0")"

APP=AirSnap.app
BIN="$APP/Contents/MacOS/AirSnap"
BUNDLE_ID="com.airsnap.app"

INSTALL_DIR="${AIRSNAP_INSTALL_DIR:-}"
if [ -z "$INSTALL_DIR" ]; then
  if [ -w /Applications ]; then
    INSTALL_DIR=/Applications
  else
    INSTALL_DIR="$HOME/Applications"
  fi
fi
INSTALL_DIR="${INSTALL_DIR%/}"
INSTALLED="$INSTALL_DIR/$APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

BUILD_TMP=$(mktemp -d)
trap 'rm -rf "$BUILD_TMP"' EXIT

# Universal binary (Apple Silicon + Intel), deployment target macOS 14
swiftc -O -target arm64-apple-macos14.0  -o "$BUILD_TMP/airsnap-arm64"  main.swift
swiftc -O -target x86_64-apple-macos14.0 -o "$BUILD_TMP/airsnap-x86_64" main.swift
lipo -create "$BUILD_TMP/airsnap-arm64" "$BUILD_TMP/airsnap-x86_64" -output "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AirSnap</string>
	<key>CFBundleIdentifier</key><string>com.airsnap.app</string>
	<key>CFBundleName</key><string>AirSnap</string>
	<key>CFBundleDisplayName</key><string>AirSnap</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ -f icon.png ]; then
  ICONSET="$BUILD_TMP/airsnap-appicon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

if [ "${1:-}" = "--build-only" ]; then
  echo "built:     $PWD/$APP"
  exit 0
fi

NEW_REQUIREMENT=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^.*designated => //p')
OLD_REQUIREMENT=""
for existing in "$INSTALLED" "/Applications/$APP" "$HOME/Applications/$APP"; do
  [ -e "$existing" ] || continue
  OLD_REQUIREMENT=$(codesign -d -r- "$existing" 2>&1 | sed -n 's/^.*designated => //p')
  if [ -z "$OLD_REQUIREMENT" ]; then
    OLD_REQUIREMENT="<unreadable-installed-requirement>"
  fi
  break
done

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALLED" || true

for other in /Applications "$HOME/Applications"; do
  [ "$other" = "$INSTALL_DIR" ] && continue
  [ -e "$other/$APP" ] || continue
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$other/$APP" || true
  rm -rf "$other/$APP"
done

echo "built:     $PWD/$APP"
echo "installed: $INSTALLED"
echo "launch:    open -a AirSnap"

if [ -n "$NEW_REQUIREMENT" ] && [ "$NEW_REQUIREMENT" != "$OLD_REQUIREMENT" ]; then
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
