#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/AI Disk Check.app"
mkdir -p "$app/Contents/MacOS" .build/modules
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modules"
arch="$(uname -m)"
xcrun swiftc -O -swift-version 5 -target "${arch}-apple-macos14.0" -parse-as-library Sources/*.swift -o "$app/Contents/MacOS/AIDiskCheck"
resources="$app/Contents/Resources"
iconset=".build/AppIcon.iconset"
mkdir -p "$resources" "$iconset"
cp -R Resources/Marks "$resources/"
cp Resources/*-LICENSE.txt "$resources/"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" Resources/AppIcon.png --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIDiskCheck</string>
<key>CFBundleIdentifier</key><string>local.aidiskcheck.mac</string>
<key>CFBundleName</key><string>AI Disk Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>pt_BR</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "dist/AI-Disk-Check-macOS-$(uname -m).zip"
