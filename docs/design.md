# Health Relay: behaviour

What every platform's Health Relay does, independent of its code. The
schema ([schema.md](schema.md)) says what a push looks like; this says when
the app sends one, what it puts in it and what it does with the answer, so
two platforms are the same product and not just the same JSON.

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

**Anchors advance only after every unpaused destination has accepted** the
batches covering the changes they reported. Until then the next sync asks
again from the old anchor and re-marks the same days; that is cheap and
never loses a change.

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

All triggers run the same single sync, serialized: a trigger that arrives
during a sync waits for it rather than starting a second.

**Automatic sync is a setting, off by default.** Off, only Sync now (and
Re-send) syncs; the platform is not asked for change notifications or a
daily wake, and any it was asked for earlier are cancelled. On, these
triggers run too:

- **Health store change notifications**, where the platform has them:
  hourly for most types, daily for sleep, stand hours and mindful
  sessions. Many types wake the app at once, so wakes are coalesced: a wake
  joins a sync already running, and a wake within **5 minutes** of the last
  sync is dropped (its changes are past the anchors, so the next sync picks
  them up). Background time is short, so a wake never waits.
- **A daily catch-up** scheduled around 06:30 local.
- **Coming to the foreground**, when the last successful sync is more
  than an hour old.

**Sync now** in the app always runs.

**Known limit (iOS):** Health data cannot be read while the phone is
locked, so changes recorded overnight are pushed after the first unlock.
The Status screen says so.

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

Per destination: last success, dirty day count, needs attention, the
retry queue and the log. Overall: last sync, the locked-phone limit, and
per type whether any data arrived in the last 30 days.
