#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product fitgap-wahoo-probe --disable-sandbox --scratch-path .build
probe_bundle="$PWD/.local/FITgapWahooProbe.app"
mkdir -p "$probe_bundle/Contents/MacOS" "$probe_bundle/Contents/Resources"
cp .build/release/fitgap-wahoo-probe "$probe_bundle/Contents/MacOS/FITgapWahooProbe"
# Core error messages now use a Swift package resource bundle.
cp -R .build/release/FITgap_FITgapCore.bundle "$probe_bundle/Contents/Resources/"
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FITgapWahooProbe</string>
  <key>CFBundleIdentifier</key><string>org.fitgap.wahoo-probe</string>
  <key>CFBundleName</key><string>FITgap Wahoo Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>org.fitgap.wahoo-oauth</string>
    <key>CFBundleURLSchemes</key><array><string>fitgap</string></array>
  </dict></array>
</dict></plist>
PLIST
plutil -lint "$probe_bundle/Contents/Info.plist"
codesign --force --sign - "$probe_bundle"
codesign --verify --deep --strict "$probe_bundle"
printf 'Lokaler Prüfclient: %s\n' "$probe_bundle"
