# Parity audit

Where Health Data Relay stands against Health Auto Export's top features, each with what backs it up. Parity is on its best features and the shape of its data, not every behaviour: its legacy v1 format and CSV layout were left out on purpose.

**How to read the evidence.** *Real* means against the real thing: real HealthKit on a simulator, a real independent server, the official client. *Simulated* means against a stand-in written here. *Compiled* means it builds and nothing more. Nothing here has run for days on a real phone, and that matters most for scheduling.

## Data formats

| Feature | State | Evidence |
|---|---|---|
| JSON v2, metrics and workouts | Done | Real: compared path by path against sanitized captures of its output. Paths and required fields match. One deliberate difference: a workout series' `source` names its sources where the original leaves it empty. |
| JSON v2, symptoms and ECG | Done | Real shape from captures, simulated data |
| JSON v2, heart rate notifications, state of mind, cycle tracking, medications | Done, shape is an educated guess | The capture phone had no such data, so these follow its documentation and the same conventions. **The likeliest place for a mismatch.** |
| GPX | Done | Real: element tree compared against captures |
| Markdown | Done | Real: headings, tables and nesting compared against captures. Differences on purpose: front matter keys say `health_` rather than the other app's prefix, and there's no record count, since output streams and the count isn't known until the end. |
| Legacy JSON v1 | Left out by decision | A link asking for it is refused with an explanation. |
| Its CSV layout | Left out by decision | Our own Metrics CSV exists, with its own columns. |
| Time grouping, summarize | Done | Simulated, including daylight saving days in several zones. Real for days. Weeks starting on the phone's first weekday is a guess. **"Automatic" meaning per minute is a guess** at its Default, which reached about 2,000 points a day. |
| Preferred sources, unit preferences | Done | Simulated. How it picks between sources wasn't observable, so per-bucket first-listed-with-data is a guess. |

## Data types

| Feature | State | Evidence |
|---|---|---|
| Metrics (all 71 seen, the 41 it had that we lacked) | Done | Real: every unit and aggregation style checked against real HealthKit on a simulator. |
| Workouts in full: activities, segments, splits, events, series, routes | Done | Simulated, plus real seeded workouts on a simulator. How it computes splits wasn't observable, so per-km and per-mile from distance samples is our own. |
| Cycle tracking, heart rate notifications, State of Mind, medications | Done | Real permission flow on a simulator. **No real medications or cycle data has been through it**, and medication sharing has its own iOS sheet, tried only with nothing to share. |
| Full-rate ECG | Done | Simulated. A real recording hasn't been through it. |

## Destinations

| Feature | State | Evidence |
|---|---|---|
| REST: method, headers, token, timeout, body or upload, automation headers | Done | Real: end to end on a simulator against the repo's receiver. **Its open-source server hasn't ingested our output**: this needed running that server and wasn't done. |
| MQTT, with TLS, QoS and retain | Done | Real: the aedes broker at all three QoS levels. **Mosquitto not yet**: `tools/mqtt-check.sh` does it once Docker is running. TLS to a broker hasn't been tried. |
| Home Assistant | Done as a preset | Simulated: request and body checked. **Not tried against a real Home Assistant.** |
| Calendar | Done | Real: EventKit on iPhone and iPad simulators. Reruns add nothing. |
| Email: SMTP | Done | Real: smtp-server with STARTTLS and a password. |
| Email: mail services | Done | Simulated: request shape only, against their documentation. **Never sent through Resend, SendGrid or Postmark.** |
| Email: compose | Done | Real on a simulator up to the file being ready. The composer itself needs a mail account, which a simulator doesn't have. |
| Files folder | Done | Simulated: writes and replaces on disk. **The system folder picker hasn't been driven by a test.** |
| Dropbox, Google Drive, Sheets | Written, not usable yet | Simulated only: including interrupted uploads. **Needs OAuth clients registered, which is yours to do**, then trying against the real services. Without them the app says it isn't set up. |
| iCloud Drive | Off by decision | Guideline 5.1.3(ii). A flag turns it on if Apple says it's allowed. |

## Triggers and running

| Feature | State | Evidence |
|---|---|---|
| Manual, schedules, time of day, when Health changes | Done | Simulated, plus countdowns on a simulator. **No multi-day soak on a real phone**, the plan's done-when for this. Whether iOS runs these when it should is the biggest unknown left. |
| Realtime, while open | Done | Simulated. |
| Background uploads, long processing time | Done | Simulated: the saved-answer path. **iOS's real background transfer and processing tasks haven't been seen to fire.** |
| Notifications, reminders | Done | Simulated: when they're raised. **Delivery on a phone not seen.** |
| Manual export, ZIP, run history, one workout | Done | Real on a simulator. 500 MB stays under the memory limit and passes `unzip -t`. |
| Activity log, diagnostics | Done | Tested to hold no tokens, header values, URL paths or pipeline names. |

## Reading and platforms

| Feature | State | Evidence |
|---|---|---|
| MCP server, 8 tools | Done | Real: the official MCP client called all 8 over HTTP; real TLS with a pinned certificate from a UI test and from the Mac. A wrong token gets 401. Its tool names weren't observable, so ours are one per section. |
| TCP JSON-RPC | Done | Real socket. Off by default, with a warning. |
| Shortcuts | Written | **Compiles, and nothing has run it.** |
| Widgets | Written | The file they read is real on a simulator. **Nobody has looked at them on a Home Screen**, though they're installed on your iPhone to try. |
| Charts | Done | Real on a simulator. |
| Deep links, 22 parameters | Done | Simulated parameter by parameter, real on a simulator through the review screen. |
| Localization | English only | A string catalog is in place. Nothing is translated, and which languages it ships wasn't observed. |
| iPad | Done | Real: the whole UI suite on a simulator. |
| Mac dashboard | Done | Real: reads the real app on a simulator over TLS. Unsigned local build. |
| Vision Pro | Compiled | No simulator runtime is installed, so it has never run. HealthKit's API is there, but what a Vision Pro can read wasn't checked. |

## Ahead of it

Custom templates in any format, HTML, multi-section pipelines, deletions reaching receivers, retries with identical bytes, and all of it free.

## What only a person or a real device can settle

1. **Device values against the Health app.** Settings › Values by day shows them side by side with what you can see in Health. This is M3's done-when, and only you can compare.
2. **Template speed on a phone.** On this Mac a week of per-second data renders in 2 to 3.5 seconds. It hasn't been measured on your iPhone.
3. **A multi-day soak** with a scheduled pipeline, comparing the activity log with what the card said.
4. **Your real cubby pipeline** still working on the new build, since that's the one that must never break. The fixture test says its bytes are unchanged.
5. **OAuth clients**, then Dropbox and Google Drive against the real services.
6. **Legal review** of using another app's data shapes and naming it in the migration guide, before any public release.
7. **App Store**: everything under "Human" in `store/RELEASE_CHECKLIST.md`.
