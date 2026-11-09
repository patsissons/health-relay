# Release checklist: Health Data Relay

Draft listing text is in [LISTING.md](LISTING.md). What's proven and what isn't, feature by feature, is in [../docs/parity-audit.md](../docs/parity-audit.md).

What stands between this repo and the first App Review submission, which is
part of milestone M5. App Store Connect record 6829337117, bundle id
`com.patsissons.healthdatarelay`, SKU `healthdatarelay`, primary language
English (U.S.), individual account. Steps marked **human** need the account
holder.

## Done

- [x] App ID registered with HealthKit (background delivery comes from the
      entitlements at build time).
- [x] App record created, which claims the name. Status: Prepare for Submission.

- [x] Phone moved to the new bundle id.
- [x] Build 0.1 (3) uploaded with `ios/scripts/testflight.sh`, for internal
      TestFlight only. **The bundle id is now locked.** App Store validation
      requires `NSHealthUpdateUsageDescription` even though Release never writes
      to Health, so Release carries a string saying so.
- [x] Build 0.1 (4) uploaded, the first with the pipelines, widgets and the new
      domain's privacy link.
- [x] Build 0.1 (5) uploaded, fixing the crash on allowing Health after adding a
      pipeline.
- [x] Build 0.1 (6) uploaded, keeping the phone awake during a run.
- [x] Build 0.1 (7) uploaded, showing overall and step progress as two bars
      that no longer jump back.

## Code (M2 to M5)

- [x] Milestones M2 to M5 complete. Template import stays out of this
      submission.
- [x] A privacy policy link inside the app (guideline 5.1.1(i) requires it
      there and in the metadata), in Settings. It goes live when the site deploys.
- [x] `PrivacyInfo.xcprivacy`: no tracking, no collected types. No required-reason
      APIs are in use.
- [x] `NSLocalNetworkUsageDescription`, since the app allows LAN destinations.
- [ ] A universal link route for setup links. They carry bearer tokens, and
      another app could claim the `healthdatarelay://` scheme.
- [ ] `MARKETING_VERSION` from 0.1 to 1.0. `device.app` in every push changes
      with it.

## Cloud accounts (human, for the build that ships them)

- [ ] OAuth clients for Dropbox and Google Drive, set in `ios/Local.xcconfig`, tried against the real services.
      Both are written and tested against simulated servers only. Google may require app verification
      for `drive.file` at scale.

## Before a public release (human)

- [ ] Legal review of matching another app's data shapes and of naming it in the migration guide
      (`site/src/content/docs/guides/moving-from-health-auto-export.md`). Its terms say users may not
      "reproduce, distribute, or create derivative works". `docs/hae-format.md` and `fixtures/hae/` stay out of
      git until this is settled.
- [ ] The Mac dashboard needs its own App Store Connect record, or a notarized download.
- [ ] Vision Pro: install its simulator and run it before listing that platform.

## Site

- [ ] Privacy policy hosted publicly, covering what the app reads, that it has
      no server, how to revoke access and how to delete data. Written, at
      `site/src/content/docs/privacy.md`; needs the site deployed.
- [ ] A support URL with a contact address.
- [ ] A public demo receiver that accepts a test token. A reviewer can't reach
      `tools/receiver.mjs` on a LAN and needs a working destination.

## App Store Connect (human)

| Field | Value |
| --- | --- |
| Primary category | Health & Fitness |
| [Regulated medical device](https://developer.apple.com/help/app-store-connect/manage-app-information/declare-regulated-medical-device-status/) | Required for this category; expected answer: No |
| [EU trader status](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/) | Your decision; a trader's contact details show on the product page |
| App Privacy | Likely "Data Not Collected", since the developer never receives the data. Check against the targets M5 ships |
| Age rating | Answer the questionnaire, including the social media questions |
| Content rights | Set up in App Information |
| Price | Free, no in-app purchases |
| Screenshots | UI test on iPhone 18 Pro Max, for 6.9-inch |
| Description, keywords, review notes | Drafted in LISTING.md. Say how to reach the demo receiver |
| App Review contact | Name, phone and email |

## Submit (human)

- [ ] Add for Review, then Submit to App Review.
- [ ] Answer any message in Resolution Center. A likely question is guideline
      5.1.1(ix), which says apps needing sensitive user information should come
      from a legal entity, while this is an individual account.
