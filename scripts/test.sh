#!/usr/bin/env bash
# Builds Debug and runs the logic self-test (scratch data under $TMPDIR only).
set -euo pipefail
cd "$(dirname "$0")/../Sweep"
xcodegen >/dev/null
xcodebuild -scheme Sweep -configuration Debug -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/SweepDev" -quiet build
"$HOME/Library/Developer/Xcode/DerivedData/SweepDev/Build/Products/Debug/Sweep.app/Contents/MacOS/Sweep" -selftest
