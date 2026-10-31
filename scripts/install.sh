#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
JARVIS_SUPPORT="$HOME/Library/Application Support/JARVIS"
JARVIS_APP="$HOME/Applications/JARVIS.app"
mkdir -p "$JARVIS_SUPPORT/models" "$HOME/Applications"
cp .runtime/models/ggml-base.en.bin "$JARVIS_SUPPORT/models/ggml-base.en.bin"
# Ask only this installation to exit before replacing its executable.
/usr/bin/swift - "$JARVIS_APP" <<'SWIFT'
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.jarvis").filter { $0.bundleURL?.standardizedFileURL == destination }
for app in running { _ = app.terminate() }
for _ in 0..<50 {
    if running.allSatisfy({ $0.isTerminated }) { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if running.contains(where: { !$0.isTerminated }) {
    fputs("JARVIS is still running. Quit it from the menu bar and run the installer again.\n", stderr)
    exit(1)
}
SWIFT
ditto dist/JARVIS.app "$JARVIS_APP"
printf '%s' "$JARVIS_SUPPORT/models/ggml-base.en.bin" > "$JARVIS_APP/Contents/Resources/speech-model-path.txt"
codesign --force --sign - --identifier com.local.jarvis "$JARVIS_APP"
open -g "$JARVIS_APP" --args "$@"
echo "Installed $JARVIS_APP"
