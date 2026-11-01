#!/usr/bin/env bash
# Bumps the build number, archives for iOS devices, checks what App Store
# signing produces, then uploads the archive to App Store Connect.
#
#   ios/scripts/testflight.sh
#
# Needs Xcode signed into the team's Apple account and xcodegen. The team comes
# from Local.xcconfig. The build number is CURRENT_PROJECT_VERSION in
# project.yml: this adds one and leaves the change for you to commit, so every
# upload has a new number. Output lands in build/ (gitignored).

set -euo pipefail

ios="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ios"

bundle_id="com.patsissons.healthdatarelay"

current="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
next=$((current + 1))
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: *\)\"$current\"/\1\"$next\"/" project.yml
version="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
echo "testflight: Health Data Relay $version ($next)"

xcodegen generate -q

archive="build/HealthDataRelay-$version-$next.xcarchive"
rm -rf "$archive"
echo "testflight: archiving"
xcodebuild -project HealthDataRelay.xcodeproj -scheme HealthDataRelay -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates -quiet archive

# Export locally first: the upload can't be taken back, and only the export
# shows the App Store signature and entitlements.
check="build/check-$version-$next"
rm -rf "$check"
mkdir -p "$check"
sed 's/<string>upload</<string>export</' scripts/ExportOptions.plist > "$check/ExportOptions.plist"
echo "testflight: checking an App Store export"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$check/ExportOptions.plist" \
  -exportPath "$check/export" -allowProvisioningUpdates -quiet
unzip -q "$check"/export/*.ipa -d "$check/ipa"
app="$check/ipa/Payload/HealthDataRelay.app"
codesign -d --entitlements :- "$app" 2>/dev/null > "$check/entitlements.plist"

fail() { echo "testflight: not uploading: $1" >&2; exit 1; }
[ "$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")" = "$bundle_id" ] || fail "wrong bundle id"
[ "$(plutil -extract CFBundleVersion raw "$app/Info.plist")" = "$next" ] || fail "wrong build number"
case "$(plutil -extract NSHealthUpdateUsageDescription raw "$app/Info.plist" 2>/dev/null)" in
  "" | Debug*) fail "needs the Release Health write string" ;;
esac
! strings "$app/HealthDataRelay" | grep -q "Writes steps, energy" || fail "the Seed tab is in the binary"
[ "$(plutil -extract com\\.apple\\.developer\\.healthkit raw "$check/entitlements.plist")" = "true" ] || fail "no HealthKit entitlement"
[ "$(plutil -extract com\\.apple\\.developer\\.healthkit\\.background-delivery raw "$check/entitlements.plist")" = "true" ] || fail "no background delivery entitlement"
[ "$(plutil -extract get-task-allow raw "$check/entitlements.plist")" = "false" ] || fail "development signed"

echo "testflight: uploading"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "build/export-$version-$next" -allowProvisioningUpdates
echo "testflight: uploaded. It appears in App Store Connect after processing. Commit project.yml."
