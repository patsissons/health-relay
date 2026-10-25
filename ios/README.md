# Health Relay for iOS

The iPhone app: SwiftUI over `HealthRelayKit`, a local Swift package that
holds all the logic (reading HealthKit, the schema, dirty days, delivery).
The behaviour it implements is in [`../docs/design.md`](../docs/design.md)
and the body it sends in [`../docs/schema.md`](../docs/schema.md).

```
ios/
├── project.yml            XcodeGen source of HealthRelay.xcodeproj (generated, not committed)
├── Config/Base.xcconfig   includes Local.xcconfig (your signing team; not committed)
├── HealthRelay/           the app: Status, Destinations, Seed (Debug only)
├── HealthRelayUITests/    end to end on a simulator against tools/receiver.mjs
└── HealthRelayKit/        the package: Sources/ and Tests/
```

## Requirements

- Xcode 27 or later, and XcodeGen (`brew install xcodegen`).
- iOS 17 or later on the phone (effort scores need iOS 18).
- A paid Apple Developer Program team: HealthKit and its background
  delivery entitlement need one.

## Build

```sh
cd ios
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM
xcodegen
open HealthRelay.xcodeproj
```

Re-run `xcodegen` after adding or removing files. The bundle id is
`com.patsissons.healthrelay`; settle it before an App Store release, since it
cannot change after one.

## Test

The package's tests need no simulator (Swift Testing, a fake HealthStore):

```sh
cd ios/HealthRelayKit && swift test
```

They include the contract check: the fixture's synthetic data read and
encoded by the kit equals `../fixtures/push-two-days.json` byte for byte.
On a simulator the same suite also checks every catalog unit against the
real HealthKit:

```sh
xcodebuild -project HealthRelay.xcodeproj -scheme HealthRelay \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:HealthRelayKitTests test
```

The UI test drives the whole app on a simulator: Health permission,
seeding a week of samples, adding a destination, Test, Sync now and the
delivery log. Start the reference receiver first:

```sh
node tools/receiver.mjs --token test-token --out /tmp/pushes   # from the repo root
TEST_RUNNER_RECEIVER_URL=http://127.0.0.1:8787/ TEST_RUNNER_RECEIVER_TOKEN=test-token \
TEST_RUNNER_SCREENSHOTS=/tmp/shots \
xcodebuild -project HealthRelay.xcodeproj -scheme HealthRelay \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:HealthRelayUITests test
```

`TEST_RUNNER_SCREENSHOTS` saves each step's screenshot; the site's
screenshots come from it.

## Run on a device

1. Sign in to Xcode with the developer account (Xcode › Settings ›
   Accounts) and set `DEVELOPMENT_TEAM` in `Local.xcconfig`.
2. Connect the iPhone, pick it as the run destination, Run. Enable
   Developer Mode on the phone when asked.
3. Status › **Allow Health access**, turn everything on.
4. Destinations › **+**: the receiver's URL and token, Save, then **Test**
   (expect a 2xx).
5. Status › **Sync now**: the first run sends the last 30 days, one day
   per request.
6. Leave it overnight and check for an unattended delivery the next morning
   in the destination's log.

A local receiver on the Mac works from the phone too: `http://<Mac's LAN
IP>:8787` (the app allows plain HTTP to local network addresses only).

## Simulator data

The simulator has no Health data. Debug builds have a **Seed** tab that
writes a week of synthetic samples (steps, energy, heart rate, HRV,
weight, sleep, mindful minutes, blood pressure, sound levels, a symptom,
runs with routes). Release builds leave it out and never ask to write.
