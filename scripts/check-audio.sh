#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build .runtime/tests
/usr/bin/say -o .runtime/tests/hands-free.aiff 'Jarvis, open Claude in Chrome.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 .runtime/tests/hands-free.aiff .runtime/tests/hands-free.wav
/usr/bin/say -o .runtime/tests/direct.aiff 'Can you open Chrome and open Instagram?'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 .runtime/tests/direct.aiff .runtime/tests/direct.wav
/usr/bin/say -o .runtime/tests/office.aiff 'Hey Jarvis, Aryan here to start working.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 .runtime/tests/office.aiff .runtime/tests/office.wav
swiftc -swift-version 5 -parse-as-library Sources/Core.swift Sources/InstagramCore.swift Sources/ProcessRunner.swift Sources/VoiceAudio.swift Sources/LiveSpeech.swift Sources/Audio.swift Tests/AudioSmoke.swift -o .build/audio-smoke -framework AppKit -framework AVFoundation -framework Speech
.build/audio-smoke .runtime/tests/hands-free.wav .runtime/models/ggml-base.en.bin .runtime/tests/direct.wav .runtime/tests/office.wav
