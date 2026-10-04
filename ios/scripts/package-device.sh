#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'XcodeGen is required on the macOS builder'; exit 1; }
xcodegen generate
xcodebuild -project Remi.xcodeproj -scheme Remi -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath DeviceDerivedData CODE_SIGNING_ALLOWED=NO build
app='DeviceDerivedData/Build/Products/Release-iphoneos/Remi.app'
test -d "$app" || { echo 'Device build did not produce Remi.app'; exit 1; }
staging=$(mktemp -d)
mkdir -p "$staging/Payload" artifacts
ditto "$app" "$staging/Payload/Remi.app"
ditto -c -k --keepParent "$staging/Payload" artifacts/Remi-unsigned.ipa
shasum -a 256 artifacts/Remi-unsigned.ipa > artifacts/Remi-unsigned.ipa.sha256
echo 'Unsigned iPhone IPA prepared. Must be signed before installation; not a TestFlight release.'
