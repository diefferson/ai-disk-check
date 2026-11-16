#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/modules
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modules"
xcrun swiftc -swift-version 5 Sources/{Git,Disk,GitHub,Store,Origins}.swift Tests/Acceptance.swift -o .build/acceptance
.build/acceptance "$@"
