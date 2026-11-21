#!/usr/bin/env bash
# Renders every screen with fake data to qa/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."
"$HOME/Library/Developer/Xcode/DerivedData/SweepDev/Build/Products/Debug/Sweep.app/Contents/MacOS/Sweep" -qa "$PWD/qa"
