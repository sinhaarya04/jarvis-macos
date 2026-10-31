#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
if [[ ! -s .build/office-greeting-female.aiff || Sources/VoiceAudio.swift -nt .build/office-greeting-female.aiff ]]; then
    # Render the same local female voice/effect used by live replies, once at build time.
    swiftc -swift-version 5 -O -parse-as-library Sources/Core.swift Sources/InstagramCore.swift Sources/ProcessRunner.swift Sources/VoiceAudio.swift Tools/PrepareGreeting.swift -framework AVFoundation -o .build/prepare-greeting
    .build/prepare-greeting .build/office-greeting-female.aiff
fi
cp .build/office-greeting-female.aiff .build/office-greeting.aiff
