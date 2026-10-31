#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -parse-as-library Sources/Core.swift Sources/InstagramCore.swift Sources/ProcessRunner.swift Tests/CoreTests.swift -o .build/core-tests
.build/core-tests
swiftc -swift-version 5 -parse-as-library Sources/Core.swift Sources/InstagramCore.swift Sources/Instagram.swift Sources/ProcessRunner.swift Sources/MacActions.swift Sources/BrowserAgent.swift Sources/LocalModel.swift Sources/ClaudeModel.swift Sources/Jev.swift Sources/Markets.swift Tests/ServiceTests.swift -o .build/service-tests -framework AppKit -framework Contacts -framework Security
.build/service-tests
node --check Resources/instagram-controls.js
node Tests/InstagramControls.test.cjs
swiftc -swift-version 5 -typecheck Sources/*.swift
plutil -lint Resources/Info.plist
for script in scripts/*.sh; do bash -n "$script"; done
git diff --check
