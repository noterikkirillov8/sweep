#!/usr/bin/env bash
# Builds Sweep (Release, signed with Erik's local certificate so macOS permissions stick) and
# makes it the only Sweep: installed in /Applications and started.
#
#   ./scripts/install.sh        (NO_OPEN=1 to install without launching)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/SweepRel"
BUILT="${DERIVED}/Build/Products/Release/Sweep.app"
TARGET="/Applications/Sweep.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# Erik's local identity when present; ad-hoc signing for everyone else.
IDENTITY="Erik Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

echo "Building (Release)..."
cd "${REPO_ROOT}/Sweep"
xcodegen >/dev/null
xcodebuild -scheme Sweep -configuration Release -derivedDataPath "${DERIVED}" CODE_SIGN_IDENTITY="${IDENTITY}" -quiet build

echo "Quitting Sweep..."
osascript -e 'tell application id "com.erikkirillov.Sweep" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Sweep >/dev/null || break; sleep 1; done
pkill -x Sweep 2>/dev/null || true

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true

if [ -z "${NO_OPEN:-}" ]; then open "${TARGET}"; echo "Sweep is running from ${TARGET}. Menu bar icon, or ⌃⌥S."; else echo "Installed ${TARGET} (not opened)."; fi
