#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen on your Mac: brew install xcodegen'; exit 1; }
command -v xcodebuild >/dev/null || { echo 'Install and select Xcode first'; exit 1; }
xcodegen generate
# Select an installed iPhone instead of assuming one model exists in this Xcode.
# Explicit DESTINATION overrides automatic selection.
if [[ -z "${DESTINATION:-}" ]]; then
  simulator_id=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
phones = [device for runtime, values in devices.items()
          if (match := re.search(r"iOS-(\d+)", runtime)) and int(match[1]) >= 17
          for device in values if device.get("isAvailable") and device["name"].startswith("iPhone")]
if not phones:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode.")
phones.sort(key=lambda device: (device["state"] != "Booted", device["name"]))
print(phones[0]["udid"])
')
  DESTINATION="platform=iOS Simulator,id=$simulator_id"
fi
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-DerivedData/TestResults-$(date +%Y%m%d-%H%M%S).xcresult}"
xcodebuild -project Remi.xcodeproj -scheme Remi -destination "$DESTINATION" -derivedDataPath DerivedData -resultBundlePath "$RESULT_BUNDLE_PATH" CODE_SIGNING_ALLOWED=NO test
