#!/bin/bash
# PRIVATE PROTOTYPE (AGPL). Packages the simulator and device builds for the RGPChiaki Swift package.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$HERE/RGPChiaki/Chiaki.xcframework"
ARGS=()
for sdk in iphonesimulator iphoneos; do
  [ -f "$HERE/out/$sdk/libchiaki-all.a" ] && ARGS+=(-library "$HERE/out/$sdk/libchiaki-all.a" -headers "$HERE/out/$sdk/include")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$HERE/RGPChiaki/Chiaki.xcframework"
