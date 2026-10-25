# Writing a receiver

A receiver is anything that accepts `POST` of the schema in
[schema.md](schema.md) and answers with a status. Health Relay assumes
nothing else about it.

## The minimum

1. Accept `POST` with a JSON body up to 16 MB.
2. Check the bearer token if you issued one; answer **401** when it is
   wrong. The app stops sending until the user fixes it.
3. Answer **400** with `{ok: false, error, message}` when `schema` is not
   `apple-push/1` or a section is not an array. The app shows `message`.
4. Answer **2xx** with `{ok: true, ...}` to an empty push (`days: []`).
   That is the app's connection test.
5. Store what you need and answer **2xx**. Answer **5xx** only when the app
   should retry the same batch later.

[`tools/receiver.mjs`](../tools/receiver.mjs) is all of that in about a
hundred lines of Node with no dependencies. Run it with
`node tools/receiver.mjs --token secret --out /tmp/pushes` and point a
destination at `http://<this machine's LAN IP>:8787`. It prints each push's
days and per-type counts, and `--out` saves every body for inspection.
`--fail 503` makes it refuse everything, to watch an app's retries.

## Storing days correctly

The rules that make a receiver agree with the phone:

- **A listed day is owned.** For each day in `days`, replace everything you
  hold for that day from this phone with what the push carries. Something
  the phone no longer has (a deleted workout) must disappear. If you keep
  only some metrics, read `covers` and own only what it lists.
- **Records outside `days` only add.** A night that began the evening
  before a listed day arrives with it; add it, do not replace that earlier
  day.
- **Newer reads win.** Batches can be retried, so an older read can arrive
  after a newer one. Keep `exportedAt` per day and ignore a push older than
  what you hold; that is still a 2xx.
- **Combine sources** as schema.md says: the largest source total for
  sums, `count`-weighted pooling for means and heart rate, the latest
  `latestAt` for spot values, energy-weighted averages for sound levels.
- **Days are local.** `day`, `days` and the date part of every timestamp
  are the phone's local date; do not convert them to UTC days.

## Worked example: cubby

cubby's health app (a personal dashboard) implements this schema at
`POST https://<host>/_cubby/apps/health/push`:

- **Auth.** The user mints a device token on the health app's Data tab
  ("Add a phone"); it is shown once and only its SHA-256 is stored. In
  Health Relay the user adds an HTTP endpoint destination with that URL
  and token.
- **Parsing.** The push runs through the same aggregator as an Apple
  Health `export.zip` upload, so a pushed day and an exported day combine
  identically. Each `stats` row is folded in as its mode says; `samples`
  go through the export.xml record path.
- **Ownership.** Listed days replace every Apple metric and event kind
  the dashboard keeps, narrowed by `covers` when present.
- **Precedence.** Pushes and manual exports share one ledger keyed by
  `exportedAt`, so whichever was read from Health later wins per day; a
  stale push answers 2xx with `days_stale` counted.
- **Answer.** `{ok: true, months_written, months_unchanged, days_stale, days, from, to}`;
  `400 bad_push` or `bad_schema` for a body that is not the schema; `401
  token_unknown`; `500 write_failed` when its store failed.

`fixtures/push-two-days.json` produces, in cubby, the same days, events
and ownership as cubby's own test body.
