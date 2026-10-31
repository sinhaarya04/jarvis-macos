#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Match LSMinimumSystemVersion in Info.plist; swiftc otherwise targets the host macOS.
mkdir -p .build dist/JARVIS.app/Contents/MacOS dist/JARVIS.app/Contents/Resources
bash scripts/prepare-greeting.sh
swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 5 -O -parse-as-library Sources/*.swift -o dist/JARVIS.app/Contents/MacOS/JARVIS -framework AppKit -framework SwiftUI -framework AVFoundation -framework Speech -framework ApplicationServices -framework Carbon -framework Contacts -framework Security -framework ServiceManagement
cp Resources/Info.plist dist/JARVIS.app/Contents/Info.plist
cp .build/office-greeting.aiff dist/JARVIS.app/Contents/Resources/office-greeting.aiff
cp Resources/instagram-controls.js dist/JARVIS.app/Contents/Resources/instagram-controls.js
# Keep the large speech model outside the bundle; the runtime uses this install-specific path.
printf '%s' "$(pwd)/.runtime/models/ggml-base.en.bin" > dist/JARVIS.app/Contents/Resources/speech-model-path.txt
codesign --force --sign - --identifier com.local.jarvis dist/JARVIS.app
printf 'Built %s/dist/JARVIS.app\n' "$(pwd)"
