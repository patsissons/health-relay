#!/bin/sh
# The Mac's client against the real iPhone app on a simulator, over real TLS,
# trusting its certificate by fingerprint. Needs a simulator named "HDR Test".
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
file="$(mktemp -u /tmp/hdr-phone-XXXXXX).json"
rm -f "$file" "$file.stop"
cd "$root/ios"
TEST_RUNNER_HDR_SERVER_FILE="$file" xcodebuild test -project HealthDataRelay.xcodeproj -scheme HealthDataRelay \
  -destination 'platform=iOS Simulator,name=HDR Test' -derivedDataPath build/sim \
  -only-testing:HealthDataRelayUITests/HealthDataRelayUITests/testServerForMacClient > /tmp/hdr-mac-check.log 2>&1 &
phone=$!
tries=0
until [ -s "$file" ]; do
  tries=$((tries + 1))
  [ "$tries" -gt 300 ] && { echo "The phone's server never came up"; kill "$phone"; exit 1; }
  sleep 1
done
cd "$root/ios/HealthDataRelayKit"
HDR_PHONE_FILE="$file" swift test --filter aRealPhone 2>&1 | grep -E "REAL PHONE|Test run with|recorded an issue|error:" || true
touch "$file.stop"
wait "$phone" && echo "The phone's side passed" || echo "The phone's side failed: see /tmp/hdr-mac-check.log"
rm -f "$file" "$file.stop"
