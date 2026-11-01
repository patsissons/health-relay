# App Store listing

Draft text for App Store Connect. It names no other app, on purpose (guidelines 4.1(c), 2.3.7 and 5.2.1).

**Name:** Health Data Relay

**Subtitle (30):** Your Health data, your way

**Promotional text (170):** Send your Apple Health data anywhere you choose, in any format, on your schedule. No account, no server of ours, nothing to pay.

**Keywords (100):** health,export,json,csv,apple health,webhook,mqtt,dashboard,gpx,api,data,backup,sync

**Description:**

Your Health data belongs to you. Health Data Relay gets it to wherever you want it.

Set up a pipeline: choose what to read, how to write it and where to send it, then run it with a tap or on a schedule. Each pipeline is a card, showing how it stands and when it runs next.

WHAT IT CAN READ
Over a hundred health metrics, workouts with routes and splits, sleep, symptoms, ECG, cycle tracking, State of Mind and medications, grouped by the second, minute, hour, day, week, month or year. Only what you allow.

HOW IT CAN WRITE
JSON, CSV, Markdown, HTML, GPX or anything else: templates are small text files you can read, change, share and write yourself, with a live preview.

WHERE IT CAN SEND
Any web address, your own mail server or a mail service, a folder, MQTT, Home Assistant, your calendar, or the share sheet.

BUILT TO BE EXACT
When a day changes, the whole day goes again, so a receiver ends up with what your iPhone has, deletions included. A failed send retries the very same output.

AND THE REST
Ask about your data from AI tools on your own network. Charts, widgets, Shortcuts, and a Mac dashboard.

PRIVATE BY DESIGN
There's no account and no server of ours. Your data goes only where you send it, directly from your iPhone. There's no analytics, advertising or tracking.

Health Data Relay moves data. It doesn't give medical advice.

**What's new:** First release.

**Support URL:** https://health-relay.lgtm.page

**Privacy policy URL:** https://health-relay.lgtm.page/privacy/

**Review notes:**

Health Data Relay has no account and no backend: it reads HealthKit and sends data to destinations the user configures, directly from the device.

To try it: allow Health access, tap +, name a pipeline and enter a web address, then tap Run. A reviewer can use [demo receiver URL, to be set up, see RELEASE_CHECKLIST.md] with bearer token [token]. Debug-only sample data isn't in this build, so a device with Health data shows the most.

HealthKit data is only ever sent to a destination the user adds. Each add shows where it will go first. Nothing is stored in iCloud: the iCloud Drive option is off in this build. Templates are declarative Liquid text with no access to the network or files, and run no code.

The app asks for Calendar access only for a pipeline that writes to a calendar, and local network access only for destinations and the optional server on the user's own network.
