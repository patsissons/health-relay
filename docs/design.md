# Health Data Relay: behaviour

What every platform's Health Data Relay does, independent of its code. The
schema ([schema.md](schema.md)) says what a push looks like; this says when
the app sends one, what it puts in it and what it does with the answer, so
two platforms are the same product and not just the same JSON.

## Pipelines

Everything the app does is a **pipeline**: **Extract** from the health store,
**Transform** into a format, **Load** into a target, with a **Trigger** saying
when. Each shows as a card: a manual one has a Run button, a scheduled one
counts down to its next run.

v1 has one Extract (the days that changed, below), one Transform (the
in-memory `Health Data Relay` format, the schema one batch at a time) and one Load
(an HTTP endpoint, a *destination* below). The app shows only the last two
parts, as the format and the destination; the Extract is not a choice yet.
Triggers:

- **Manual**: runs only when the user taps Run. The default.
- **When Health changes**: the triggers under [When to sync](#when-to-sync).
- **A schedule**: every N minutes, hours, days or weeks after its last run.

- **At a time**: a time of day, on chosen days. A time the clocks skip runs just after it.

A schedule of under a minute runs only while the app is open, since iOS has no background work
that often. A scheduled template pipeline also asks iOS for its longer processing time, because
writing output can take more than a refresh allows. Parts of 1 MB or more upload with iOS's
background transfer service, so they keep going once the app is suspended. The answer is saved, so
the next run acts on it instead of sending the part again.

A pipeline's id is its destination's, so a token, queue and log saved before
pipelines existed are its own. State saved before triggers existed needs no
rewriting: a pipeline with no saved trigger is *when Health changes* if the old
automatic sync setting was on, and manual if not.

## What a pipeline can read

An Extract says which **sections** it wants (metrics, workouts, symptoms, ECG,
heart rate notifications, state of mind, cycle tracking, medications), which
metrics, how much time, and how values combine. The catalog of metrics is wider
than the native push's and separate from it, so adding a metric can't change
what an existing receiver gets.

**Range.** Whole days that changed; since the last run; today; yesterday; the
previous N days; the last N days including today; a fixed range; or asked when
Run is tapped. Since the last run also picks up older samples that arrived
late, and a first one looks back 7 days.

**Grouping.** Seconds to years, or automatic, which is minutes, or none, which
writes each sample as it is. Only buckets with data produce a point. Buckets
fall on local time: a day is midnight to midnight, so 23 or 25 hours when the
clocks change, and each of those hours gets its own bucket. Weeks start on the
phone's first day of the week. A range grows outward to whole buckets, so a
point is never built from part of its bucket.

**Sources.** Merged is Health's own combined value with overlaps removed, what
the Health app shows, with `source` listing every contributor. Each source
gives one point per source. Preferred takes the first listed source with data
in each bucket and falls back to merged. Without grouping there are no buckets,
so preferred keeps only the first listed source with any data.

**Sleep.** Summarized sleep is one point per night, dated the morning it ended.
A gap over 4 hours starts a new night. Several sources often record one night,
so each moment counts once, for the most specific stage recorded: a stage, then
plain asleep, then awake, then in bed. There's no sleep point below a day, and
weeks and longer add their nights together.

**Large reads.** Everything comes in pages of 2,000 samples and nothing past the
current page is held, because one metric can run to millions of samples.

## Templates

A **template** is a text file describing how what was read becomes the text
delivered. [templates.md](templates.md) is its contract. The native format stays
native code, with its batching and bytes unchanged. A template twin of it ships for
people to copy, and a test holds it to the fixture byte for byte.

The built-in templates are **Metrics JSON v2** (metrics, workouts and any other section turned on,
in one document, where a section with no data is left out and `metrics` is always there. Other
sections are opt-in, and medications have an iOS sheet of their own), **Health Report Markdown** (one file per
section) and **Workout Routes GPX** (one file per workout with a route). Splits and segments are
worked out from one read of a workout's samples: per kilometre and per mile, assuming even progress
within a sample, and using only the workout's own source when it has samples, since other sources
often record the same movement.

## Template library

The **Templates** tab lists the built-ins and the user's own, saved as text files in
`templates/`. A built-in can be read, shared or copied to edit. An edit that doesn't parse
can't be saved, so a pipeline can't break on a half-finished change. The editor shows the
line and column of any mistake, and its preview runs the template on sample data, or on the
last three days of real data if asked, without sending anything.

Removing a template that a pipeline uses leaves that pipeline asking for another on its card.

## Manual exports

**Export**, on the Pipelines screen, writes a template over chosen dates to a file to share, with
no pipeline and nothing remembered. It can also export one workout. One file keeps its name, and
several go in a ZIP, written a piece at a time so a large export costs no memory.

A pipeline can do the same with **Share sheet** as its destination: a run leaves a file on its
screen, replaced by the next run, and "delivered" means ready to share. A range of **Ask when
run** asks for dates when Run is tapped, so it needs a manual trigger.

Each run of a template pipeline is recorded with its rows, size and file count, in **Run history**.

## MQTT, Home Assistant and Calendar

**MQTT** publishes each part as one message over MQTT 3.1.1, optionally with TLS, at QoS 0, 1 or 2, retained if
asked. A part over 64 MB is refused, since a message is held in memory: split it with a partition.
A refused password stops the pipeline, and an unreachable broker retries. The topic can be a template,
rendered per part.

**Home Assistant** isn't a target of its own. It's a preset: a web target at `/api/states/sensor.health_<metric>`
with a long-lived token, and a template writing one sensor per metric that has data.

**Calendar** writes events a template lists as `{"events": [{"key", "title", "start", "end", "allDay", "notes", "location"}]}`.
Which event each key became is saved, so running again updates an event rather than adding one, and an event the
user deleted is made again. Only events a pipeline made are touched.

## Email

A run sends one email, with its output attached: one file, or a ZIP of several. There's no server of ours.

- **SMTP** runs unattended with the user's own account. STARTTLS is the default and refuses to carry on if a
  server doesn't offer it, so a password or health data never falls back to the clear. Sending with no TLS is a
  choice with a warning, for a server on the user's own network. The message streams from a file, so a large
  attachment costs no memory.
- **A mail service** (Resend, SendGrid or Postmark) runs unattended with the user's API key, up to 25 MB.
- **Mail or another app** needs a tap. A run leaves the file ready, with Apple Mail's composer when it's set up and the
  share sheet for Gmail and others. A run nobody tapped sends a notification saying it's ready.

A retry keeps the same Message-ID, or idempotency key where a service has one, so a server can recognise a repeat.

## Files and cloud storage

A pipeline can save each part as a file: to a folder the user picked in the Files app, to Dropbox, or to Google Drive, replacing a file of the
same name or keeping both. A folder's file appears whole or not at all. Cloud accounts are shared in Settings, signed in with OAuth and PKCE, so no
secret ships in the app. Their tokens live in the Keychain, and an expired one refreshes on its own.

A large cloud upload goes in 8 MB chunks with its position saved, so an interrupted one carries on where it stopped: Dropbox from the saved offset, and Google by
asking how much arrived. Google Drive can turn a CSV into a Sheet as it uploads, and its `drive.file` access only reaches files this app made.

**iCloud Drive is off.** Guideline 5.1.3(ii) says apps "may not store personal health information in iCloud", so a folder there is refused until
Apple has answered whether a file a user chose to put there themselves counts. `Features.iCloudDriveFolders` turns it on.

## The on-device server

Off unless turned on, and running only while the app is open, since iOS suspends a backgrounded app.

**MCP** answers over HTTPS on the phone's network, at `/mcp`, with one tool per section: `health_metrics`, `workouts`, `symptoms`, `ecg`,
`heart_rate_notifications`, `state_of_mind`, `cycle_tracking` and `medications`. Each takes `start` and `end` dates, and metrics also take `metrics` and
`grouping`. A tool returns the same JSON a pipeline writes, up to 8 MB. A request needs the bearer token the app shows, compared in constant
time, and a wrong one gets 401. Its certificate is made on the phone and shown by fingerprint, because no public authority can vouch for a home network.
It's remade if the phone's address changes, and nothing else can reach the key in the Keychain.

**TCP** is newline-separated JSON-RPC with the same tools, for tools that can't use MCP. It has no password and no encryption, so it's off by default, separate
from MCP, and the screen says plainly that anyone on the network can read Health data while it's on.

## Notifications and activity

A pipeline can notify when it fails, when it finishes, and, if scheduled, a few minutes after it's
due if it hasn't run: iOS can't promise a time, so the reminder is the honest backstop. Notifications
never hold a health value.

**Settings › Activity** lists what the app did and when. A diagnostics file zips that with each
pipeline's settings, for a bug report. It leaves out health values, tokens, header values, URL paths,
pipeline names and template text.

## Delivering a template's output

A run writes each part to disk before anything is sent, in
`pipelines/<id>/queue/<artifact>/`, under its final name only once it's complete. A
retry sends those bytes rather than reading Health again, so a retry after new data
arrives still sends what the run first saw, and a killed app carries on where it
stopped. A half-written folder is never sent and is cleared at the next run. A
pipeline's saved position moves only once its output is safe on disk.

Parts deliver in order, and one that's accepted isn't sent again. A failure follows
the destinations' rules below. A refused part drops the whole artifact, since the rest
is the same run. A template error needs fixing, so it stops the pipeline rather than
retrying.

A run that finds output left from an earlier one delivers that and stops, rather than
also reading a new range: the next run reads from where this left off. Since the last
run sends nothing if nothing is new. Days that changed always send, because an empty day
is how a deletion arrives.

A pipeline with its own range collects no dirty days, so it can't hold the shared
anchors back. One following changed days watches any type outside the native catalog
with anchors of its own.

The web target sends a request per part, streamed from its file, with any method, headers
and bearer token, as a body or a file upload. Its address may be a template, rendered per
part when the output is written. **Test** runs the template over no data, so a receiver
sees the shape it will get with nothing in it. Automation headers (`automation-name`,
`automation-id`, `automation-aggregation`, `automation-period`, `session-id`) are on by default,
and a `session-id` is new per request.

## Destinations

The app holds a list of destinations. Each has a type, a name, a paused
flag and its own delivery state. v1 has one type, **HTTP endpoint**: a URL,
an optional bearer token (kept in the platform's secure store, never in
plain files), optional extra headers, and the schema as the body. A new
type (a file in iCloud Drive, MQTT, a templated webhook) implements one
operation, *deliver this batch and report the verdict*, and reuses
everything below.

The user sees the word "destination" and the destination's own name. The
app never names a particular receiver.

**Test** sends the empty push (`fixtures/empty-push.json` shape, with the
real device) and shows the receiver's answer. **Pause** keeps a
destination's dirty days accumulating without sending. **Remove** deletes
its dirty days, queue and log; removing the last destination also resets
the change anchors, so adding one later starts as a first run.

## Which days to send

A day is a local calendar day in the phone's current time zone, midnight to
midnight (23 or 25 hours across a daylight saving change).

Each destination has its own set of **dirty days**. A day becomes dirty for
every destination when:

- **new samples arrive.** The app asks the health store for what changed
  since a persisted anchor per type and marks the local day of each added
  sample dirty (both the start day and the end day when they differ).
  Deleted objects carry no date and are ignored here; the weekly sweep
  catches them.
- **it is today or yesterday.** These are dirty on every sync.
- **the weekly sweep runs.** Once every 7 days the last 35 days are marked
  dirty. That catches deletions and late watch syncs. The user can do the
  same on demand ("Re-send last N days").
- **it is a first run.** A destination added with no history gets the last
  30 days, sent oldest first, one day per batch, so the first useful data
  lands quickly and a failure costs one day.

**Never before the readable window.** The user may let the app read only
some history (iOS 27 offers "past 30 days and future data"). No rule above
marks a day earlier than 29 days before access was first granted: a listed
day is owned, so listing a day the app cannot read would erase it at the
destination.

A day leaves a destination's dirty set only when that destination answered
2xx to a batch listing it, and only if the day was not marked dirty again
after that batch was read (a change that landed mid-flight is sent next
time).

**Anchors advance only after every pipeline in the run has accepted** the
batches covering the changes they reported. Until then the next sync asks
again from the old anchor and re-marks the same days; that is cheap and
never loses a change. A pipeline outside the run is marked like the others and
keeps its marks, so one that is only ever tapped holds nothing up.

Changes reach back at least 40 days, and as far as the last delivery of the
pipeline that has gone longest without one, so a pipeline left unused for months
misses nothing. Older data added by another app does not re-send old days.

## What a batch holds

A batch lists up to **7 dirty days**, or fewer when the JSON would pass
**about 1 MB**, whichever comes first (first runs: 1 day). For each listed
day it carries *everything* the phone has for that day in every section,
because a listed day is owned by the push (schema.md, Ownership). Reading
is per day; a day that fails to read is not listed.

Days are sent oldest first. A batch is serialized once, written to disk,
and that file is what is sent and retried, so a retry sends the same bytes
with the same `exportedAt`.

## Sending and the answer

- One batch in flight per destination; **1 second** between batches to
  the same destination (receivers may rate-limit). Destinations are
  independent: one failing never holds another.
- HTTP: JSON body, `Authorization: Bearer <token>` when set, extra
  headers, `Content-Type: application/json`, **30 s** timeout.
- **2xx**: the batch's days leave the dirty set; the file is deleted; the
  answer's message goes in the destination's log.
- **401 / 403**: the destination is marked *needs attention* and nothing
  more is sent to it until the user edits it (or taps Test and it passes).
  Its days stay dirty.
- **400**: the receiver's message is surfaced; the batch is dropped (the
  same bytes would fail again) and its days stay dirty, so a fixed app or
  receiver resends them.
- **5xx, 429, network errors, timeouts**: kept on disk and retried on the
  next trigger, with exponential backoff per destination (1 min doubling
  to 6 h, reset by any success).

The log keeps the last 50 deliveries per destination: time, days, status
and the receiver's message.

## When to sync

One run at a time: a trigger that arrives during a run waits for it rather
than starting a second, and a tapped Run shows as queued. A run covers only the
pipelines whose trigger wants it, so running one never runs the others.

With every pipeline manual, the platform is not asked for change notifications
or a wake, and any it was asked for earlier are cancelled. A pipeline set to
**when Health changes** runs on these:

- **Health store change notifications**, where the platform has them:
  hourly for most types, daily for sleep, stand hours and mindful
  sessions. Many types wake the app at once, so wakes are coalesced: a wake
  joins a sync already running, and a wake within **5 minutes** of the last
  sync is dropped (its changes are past the anchors, so the next sync picks
  them up). Background time is short, so a wake never waits.
- **A daily catch-up** scheduled around 06:30 local.
- **Coming to the foreground**, when the last successful sync is more
  than an hour old.

A **scheduled** pipeline is due one interval after its last finished run and
runs at the first chance after that: the platform's background refresh, a change
notification, coming to the foreground, or the moment its countdown ends while
the app is open. The platform decides when background work happens, so the card
says *Due, waiting for iOS* (or *Due, unlock your iPhone* when a read failed for
that reason) rather than claim a run. A run that could not finish stays due. A
failed delivery retries when its backoff ends, without waiting for the next
interval.

**Run** always tries: it goes after whatever is running and ignores a backoff,
the same bytes first. A pipeline that needs attention stays stopped until it is
fixed, and its Run button says so.

**Background time is limited.** A run started by a change notification or the
platform's refresh starts no more work after **25 seconds**, or as soon as the
platform says its time is up. It stops between types and batches, so what is
under way can finish, and the next run carries on. Run and coming to the
foreground have no limit, and tapping Run during a background run lifts it.

**Saved state is never overwritten by accident.** Delivery progress is saved
as each batch is accepted, so a killed app does not resend what was delivered.
A state file that cannot be read yet (a wake before the first unlock) is left
alone and nothing is saved until it can be. One that cannot be decoded is set
aside, and the app says so and starts fresh.

**Known limit (iOS):** Health data cannot be read while the phone is
locked, so changes recorded overnight are pushed after the first unlock.
The Settings screen says so.

## What the app reads

Every type the schema names, through the health store's own aggregation
where it is exact: daily sums and latest values per source come from the
store's statistics; means and heart rate are computed from the day's
samples per source so `count` is exact. Read authorization covers every
type; a platform that does not report denials (iOS) shows "no data in 30
days" per type instead.

Never read or sent: clinical records, a person's name or date of birth,
anything not in the schema.

## Status the app shows

Per pipeline: last success, dirty day count, needs attention, the retry
queue, the log, and when it runs next. Overall: the locked-phone limit, and per
type whether any data arrived in the last 30 days.
