#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
OUT=.build/office-greeting-female.aiff
# Re-render when the greeting text (Tools/), the voice effect or the say invocation changes.
if [[ ! -s "$OUT" || -n "$(find Sources/VoiceAudio.swift Sources/ProcessRunner.swift Tools/PrepareGreeting.swift -newer "$OUT")" ]]; then
    # Render the same local female voice/effect used by live replies, once at build time.
    swiftc -swift-version 5 -O -parse-as-library Sources/Core.swift Sources/InstagramCore.swift Sources/ProcessRunner.swift Sources/VoiceAudio.swift Tools/PrepareGreeting.swift -framework AVFoundation -o .build/prepare-greeting
    .build/prepare-greeting "$OUT"
fi
cp "$OUT" .build/office-greeting.aiff
