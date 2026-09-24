#!/usr/bin/env bash
# Builds build/Ballast.app (menu-bar-only, ad-hoc signed).
# Accessibility permission is granted to the app bundle; ad-hoc signatures
# change on every rebuild, so macOS may ask again after rebuilding.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/Ballast.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/ballast "$app/Contents/MacOS/ballast"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ballast.Ballast</string>
  <key>CFBundleName</key><string>Ballast</string>
  <key>CFBundleExecutable</key><string>ballast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Ballast</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
echo "install: cp -R $app /Applications/ && cp scripts/dev.ballast.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/dev.ballast.plist"
