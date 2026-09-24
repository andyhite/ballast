#!/usr/bin/env bash
# Builds build/Ballast.app (menu-bar-only) and signs it.
#
# Accessibility permission is keyed to the app's designated requirement. With
# a real identity that is "bundle id + certificate", which survives rebuilds;
# an ad-hoc signature is a per-build hash, so every rebuild loses the grant.
#
#   SIGN_ID="Ballast Dev" (default)  self-signed code-signing certificate
#   SIGN_ID=-                        ad-hoc (permission lost on every rebuild)
#
# Install or update with scripts/install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

sign_id=${SIGN_ID:-Ballast Dev}
if [ "$sign_id" != "-" ] && ! security find-identity -p codesigning | grep -qF "\"$sign_id\""; then
  echo "signing identity '$sign_id' not found in the keychain" >&2
  echo "create it (Keychain Access > Certificate Assistant > Create a Certificate," >&2
  echo "Self-Signed Root, Code Signing) or build ad-hoc with SIGN_ID=-" >&2
  exit 1
fi

swift build -c release
app=build/Ballast.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp .build/release/ballast "$app/Contents/MacOS/ballast"
# LaunchAgent registered by SMAppService for "Start at Login".
cp scripts/dev.ballast.plist "$app/Contents/Library/LaunchAgents/dev.ballast.plist"

# App icon: assets/AppIcon.png (1024x1024, Apple icon grid) -> AppIcon.icns.
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ballast.Ballast</string>
  <key>CFBundleName</key><string>Ballast</string>
  <key>CFBundleExecutable</key><string>ballast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Ballast</string>
</dict>
</plist>
PLIST
codesign --force --sign "$sign_id" "$app"
codesign --verify --strict "$app"
echo "built $app"
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
echo "install or update: scripts/install.sh"
