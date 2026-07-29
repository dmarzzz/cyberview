#!/bin/zsh
# Build CyberView.app and install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/CyberView.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/CyberView"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/CyberView.icns ]] && cp Resources/CyberView.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

rm -rf ~/Applications/CyberView.app
mkdir -p ~/Applications
ditto "$APP" ~/Applications/CyberView.app

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f ~/Applications/CyberView.app
# keep the intermediate bundle out of the Open With menu
"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf build

echo "installed → ~/Applications/CyberView.app"
