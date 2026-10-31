# Release checklist: Health Data Relay

What stands between this repo and the first App Review submission, which is
part of milestone M5. App Store Connect record 6829337117, bundle id
`com.patsissons.healthdatarelay`, SKU `healthdatarelay`, primary language
English (U.S.), individual account. Steps marked **human** need the account
holder.

## Done

- [x] App ID registered with HealthKit (background delivery comes from the
      entitlements at build time).
- [x] App record created, which claims the name. Status: Prepare for Submission.

## Before the first upload

- [ ] Move the phone to the new bundle id. iOS treats it as a new app, so it
      needs a new Health grant, a new token and one 30-day resend.
- [ ] Upload one internal TestFlight build. **This locks the bundle id for
      good.** No App Review is involved.

## Code (M2 to M5)

- [ ] Milestones M2 to M5 complete. Template import stays out of this
      submission.
- [ ] A privacy policy link inside the app (guideline 5.1.1(i) requires it
      there and in the metadata; the app has none today).
- [ ] `PrivacyInfo.xcprivacy`: no tracking, no collected types. Check for
      required-reason APIs again at this point.
- [ ] `NSLocalNetworkUsageDescription`, since the app allows LAN destinations.
- [ ] A universal link route for setup links. They carry bearer tokens, and
      another app could claim the `healthdatarelay://` scheme.
- [ ] `MARKETING_VERSION` from 0.1 to 1.0. `device.app` in every push changes
      with it.

## Site

- [ ] Privacy policy hosted publicly, covering what the app reads, that it has
      no server, how to revoke access and how to delete data.
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
| Description, keywords, review notes | Say how to reach the demo receiver |
| App Review contact | Name, phone and email |

## Submit (human)

- [ ] Add for Review, then Submit to App Review.
- [ ] Answer any message in Resolution Center. A likely question is guideline
      5.1.1(ix), which says apps needing sensitive user information should come
      from a legal entity, while this is an individual account.
