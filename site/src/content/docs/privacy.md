---
title: Privacy policy
description: What Health Data Relay reads, where it goes and how to stop it.
---

**Your health data never leaves your control. There is no central Health Data Relay server, so nothing of ours processes, stores or receives your health data, and there's no account to create.**

## What the app reads

The Health data you allow in the iOS Health permission sheet. You can choose types one by one, and iOS doesn't tell the app which ones you turned off.

## Where your data goes

Only to the destinations you add. A destination is a web address, file location or other target you type in or scan from a setup link. The app sends your data there directly from your iPhone, and what happens to it after that is up to whoever runs that destination.

If you turn on the server in Settings, tools on your own network that have its token can read your Health data while the app is open. That includes the optional Mac dashboard, which keeps a copy of what it last read on that Mac.

The app includes no analytics, advertising or tracking.

## What's kept on your iPhone

- Your pipelines and their settings
- Bearer tokens and other credentials, in the iOS Keychain
- A log of recent deliveries
- Output waiting to be sent, removed once delivered
- A summary for the widgets: today's steps, energy, exercise, resting heart rate, sleep and weight, and how your pipelines stand

None of this is included in iCloud or device backups, except for what iOS backs up in the Keychain.

## Stopping and deleting

- **Stop one pipeline:** pause or remove it. Removing it deletes its settings, credential, log and queued output.
- **Stop reading Health:** Settings › Health › Data Access & Devices › Health Data Relay.
- **Delete everything:** delete the app.

Data already delivered to a destination stays there. Ask whoever runs it to delete it.

## Medical use

Health Data Relay moves data. It doesn't give medical advice, diagnose anything or check that data is right for medical use.

## Contact

Open an issue at [github.com/patsissons/health-relay](https://github.com/patsissons/health-relay/issues).
