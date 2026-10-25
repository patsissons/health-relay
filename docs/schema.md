# The Health Relay schema (`apple-push/1`)

What Health Relay sends to a destination, on every platform. One push is
one JSON object describing some local days of Apple Health (or another
platform's health store, in the same terms). A receiver that implements
this document can be any HTTP endpoint; cubby's health app
(`POST /_cubby/apps/health/push`) is one that does, and is the reference
the fixtures are checked against.

The wire name `apple-push/1` is kept because the field names are Apple
Health's own (`export.xml` attributes and HealthKit identifiers). A breaking
change gets a new name; adding an optional field does not.

Examples: [`fixtures/push-two-days.json`](../fixtures/push-two-days.json)
(two full days, every section) and
[`fixtures/empty-push.json`](../fixtures/empty-push.json) (the connection
test). Both are in [canonical form](#canonical-json).

## Request

```
POST <destination URL>
Content-Type: application/json
Authorization: Bearer <token>        (when the destination has one)
<any extra headers the user configured>
```

The body is one JSON object, at most 16 MB. Senders keep a batch to a few
days (Health Relay sends at most 7 days or about 1 MB per batch, see
[design.md](design.md)) and never more than 62 days in one push.

## Body

```jsonc
{
  "schema": "apple-push/1",
  "device": { "name": "Pat’s iPhone", "model": "iPhone17,1", "os": "26.0", "app": "Health Relay 0.1" },
  "exportedAt": "2026-10-25T14:00:00Z",      // when the phone read Health, UTC; the push's as-of
  "tz": "America/Vancouver",                 // the phone's time zone when it read
  "days": ["2026-10-24", "2026-10-25"],      // every local day this push describes in full
  "covers": { "metrics": [...], "kinds": [...] },   // optional: see Ownership
  "stats": [ ... ],                          // per-day, per-source statistics of quantity types
  "samples": [ ... ],                        // raw samples, in export.xml terms
  "workouts": [ ... ],
  "summaries": [ ... ],                      // Activity ring summaries
  "ecg": [ ... ]
}
```

Every section is optional; a missing section is the same as an empty one.
`device.name` is whatever the user calls the phone. Never send a person's
name, date of birth or other identity beyond that.

Dates inside the sections use the export.xml form, local time with its
offset: `"2026-10-24 17:00:00 -0700"`. The day of a sample is the local date
as written. `day` and `days` are `yyyy-MM-dd` local dates.

### `stats`: quantity types, one row per (type, day, source)

A local day (midnight to midnight, so 23 or 25 hours across a daylight
saving change) of one quantity type from one source. `source` is the source
app or device name as Health shows it. Which fields a row carries follows
the type's mode:

| Mode | Fields | Types |
|---|---|---|
| sum | `sum` | steps, distances, energy burned, exercise and stand minutes, flights, falls, daylight, everything dietary |
| mean | `avg`, `count` | HRV (SDNN, RMSSD), resting and walking heart rate, heart rate recovery, respiratory rate, SpO2, physical effort, walking and stair metrics, rowing speed, sound reduction |
| heart rate | `avg`, `count`, `min`, `max` | `HKQuantityTypeIdentifierHeartRate` |
| spot | `latest`, `latestAt` | weight, body fat, lean mass, BMI, height, VO2 max, walking steadiness, six-minute walk |

```jsonc
{ "type": "HKQuantityTypeIdentifierStepCount", "day": "2026-10-24", "source": "Watch", "unit": "count", "sum": 9500 }
{ "type": "HKQuantityTypeIdentifierHeartRate", "day": "2026-10-24", "source": "Watch", "unit": "count/min", "avg": 70, "count": 200, "min": 48, "max": 150 }
{ "type": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "day": "2026-10-24", "source": "Watch", "unit": "ms", "avg": 40, "count": 3 }
{ "type": "HKQuantityTypeIdentifierBodyMass", "day": "2026-10-24", "source": "Withings", "unit": "lb", "latest": 176.37, "latestAt": "2026-10-24 07:10:00 -0700" }
```

A receiver combines rows across sources the way the raw samples would
combine: sums take the largest source total (iPhone and Watch both count the
same walk), means and heart rate pool by `count`, spot values take the
latest `latestAt`. A mean row without a positive `count` carries no weight.

`unit` is the HealthKit unit string the value is in. Health Relay sends
`count`, `count/min`, `kcal`, `km`, `kg`, `%`, `ms`, `min`, `cm`, `km/hr`,
`m/s`, `m`, `mL/(kg·min)`, `kcal/hr·kg`, `dBASPL`, `degC`, `g`, `mg`, `mcg`,
`mL`, `appleEffortScore`; a receiver should accept any unit it can convert
(`lb`, `mi`, `kJ`, `degF`…). Percentages are fractions (`0.215` is 21.5 %)
as HealthKit gives them.

Three kinds of quantity go in `samples` instead, because combining them
needs each sample: sound levels (environmental and headphone exposure,
averaged by energy over each sample's duration), blood pressure (paired by
reading), and wrist temperature (filed under the morning it ends). A
receiver ignores a `stats` row for these types.

### `samples`: raw records

The attributes of an export.xml `Record`. `value` is a string. Category
values are their HealthKit names; a category with no value (a mindful
session) is `HKCategoryValueNotApplicable`.

```jsonc
{ "type": "HKCategoryTypeIdentifierSleepAnalysis", "sourceName": "Watch", "startDate": "2026-10-23 23:10:00 -0700", "endDate": "2026-10-24 02:00:00 -0700", "value": "HKCategoryValueSleepAnalysisAsleepCore" }
{ "type": "HKCategoryTypeIdentifierAppleStandHour", "sourceName": "Watch", "startDate": "2026-10-24 09:00:00 -0700", "endDate": "2026-10-24 10:00:00 -0700", "value": "HKCategoryValueAppleStandHourStood" }
{ "type": "HKQuantityTypeIdentifierEnvironmentalAudioExposure", "sourceName": "Watch", "startDate": "2026-10-25 12:00:00 -0700", "endDate": "2026-10-25 12:30:00 -0700", "value": "60", "unit": "dBASPL" }
{ "type": "HKQuantityTypeIdentifierBloodPressureSystolic", "sourceName": "Cuff", "startDate": "2026-10-25 08:00:00 -0700", "endDate": "2026-10-25 08:00:00 -0700", "value": "121", "unit": "mmHg" }
{ "type": "HKCategoryTypeIdentifierHeadache", "sourceName": "iPhone", "startDate": "2026-10-25 15:00:00 -0700", "endDate": "2026-10-25 15:00:00 -0700", "value": "HKCategoryValueSeverityMild" }
{ "type": "HKCategoryTypeIdentifierMindfulSession", "sourceName": "iPhone", "startDate": "2026-10-25 20:00:00 -0700", "endDate": "2026-10-25 20:12:00 -0700", "value": "HKCategoryValueNotApplicable" }
{ "type": "HKQuantityTypeIdentifierWorkoutEffortScore", "sourceName": "Watch", "startDate": "2026-10-24 17:40:00 -0700", "endDate": "2026-10-24 17:40:00 -0700", "value": "7", "unit": "appleEffortScore" }
```

Sent here: sleep analysis, stand hours, audio exposure events, mindful
sessions, symptoms (any category type valued by severity or presence),
blood pressure (systolic and diastolic as separate samples sharing a
`startDate`), sound levels, wrist temperature, and the two workout effort
score types (a receiver matches each to the workout whose window holds it;
a rated `WorkoutEffortScore` beats an `EstimatedWorkoutEffortScore`). A
sender may also send any quantity type raw instead of as statistics.

### `workouts`

An export.xml `Workout` with its `WorkoutStatistics` and the route's
points. Numbers are strings, as in export.xml.

```jsonc
{
  "workoutActivityType": "HKWorkoutActivityTypeRunning",
  "sourceName": "Watch",
  "startDate": "2026-10-24 17:00:00 -0700",
  "endDate": "2026-10-24 17:45:00 -0700",
  "duration": "45", "durationUnit": "min",
  "stats": [
    { "type": "HKQuantityTypeIdentifierActiveEnergyBurned", "sum": "420", "unit": "kcal" },
    { "type": "HKQuantityTypeIdentifierDistanceWalkingRunning", "sum": "7.5", "unit": "km" },
    { "type": "HKQuantityTypeIdentifierHeartRate", "average": "151.4", "maximum": "172", "unit": "count/min" }
  ],
  "route": [ { "lat": 49.28, "lon": -123.12, "ele": 10 }, ... ]   // ele in metres, or null
}
```

`route` carries every location the workout recorded; the receiver
simplifies it. It is absent when the workout has no route.

### `summaries`: Activity rings

One `HKActivitySummary` per day: the stand hours the ring counted (they
beat the stand-hour samples) and the Move goal.

```jsonc
{ "dateComponents": "2026-10-24", "appleStandHours": "11", "activeEnergyBurnedGoal": "600", "activeEnergyBurnedGoalUnit": "kcal" }
```

### `ecg`

One recording: when, the classification, the sample rate in Hz, the
average heart rate and the voltages in microvolts (integers). Health Relay
sends 128 Hz: the phone averages each block of 4 samples of Apple's 512 Hz
trace. A receiver must honour `rate` whatever it is.

```jsonc
{ "recorded": "2026-10-25 09:00:00 -0700", "classification": "Sinus Rhythm", "rate": 128, "avgHr": 61, "samples": [ 15, 54, 92, ... ] }
```

## Ownership: what a listed day means

Every day in `days` is described in full: on those days the push owns every
metric and every event kind (workout, sleep, blood pressure, symptom, stand,
ECG) the receiver keeps, so a value the phone no longer has is removed. A
sender that reads only some types declares what it read in `covers`
(`metrics` and `kinds`, in the receiver's own ids) so the rest is left
alone. A push with no `days` owns nothing and can only add.

Because ownership removes, a sender puts a day in `days` only when the push
carries everything it has for that day across all sections. Records that
spill outside the listed days (a night that began the evening before) are
allowed and are added, not owned.

## Response

A receiver answers 2xx when it accepted the push, with a JSON body:

```jsonc
{ "ok": true, "days": 2, "from": "2026-10-24", "to": "2026-10-25", ... }   // further counts are the receiver's own
```

The status alone is the verdict; the body's fields beyond `ok` are for
display. A sender shows the receiver's `message` or `error` when there is
one.

| Status | Meaning | Sender does |
|---|---|---|
| 2xx | accepted (a receiver may keep an older day it knows to be newer; that is not an error) | marks the days delivered |
| 400 | the body is not this schema; `{ok: false, error, message}` | surfaces the message, keeps the days pending, does not retry the same batch |
| 401, 403 | the credential is wrong or revoked | surfaces it, stops sending to that destination until the user fixes it |
| 5xx, network error | the receiver failed | retries later with backoff |

**Connection test.** A receiver must answer 2xx to an empty push
(`days: []`, no sections), the body in `fixtures/empty-push.json`. That is
the whole test; there is no GET or destination-specific probe.

## Canonical JSON

Health Relay sends canonical JSON, and the fixtures are stored in it, so
any platform's output can be compared byte for byte:

- object keys sorted at every level by UTF-16 code unit (`Array.prototype.sort`);
- no whitespace;
- strings escaped exactly as `JSON.stringify` escapes them (so `/` and
  non-ASCII are not escaped);
- numbers as `JSON.stringify` writes them: shortest round-trip form,
  integers without a decimal point, exponent only below 1e-6 or from 1e21.

`node tools/canonical.mjs --check <file>` checks a file.
Receivers must not depend on key order or formatting.

## The fixtures and cubby's test body

`fixtures/push-two-days.json` is cubby's test body (`pushBody()` in cubby's
`scripts/health-fixture.mjs`) as Health Relay itself would send it. cubby's
body also exercises a receiver's rejections, so the fixture differs:

- no `HKQuantityTypeIdentifierNotAThing` row and no `stats` row for a
  sound-level type (a receiver must ignore both; a sender never sends them);
- sum rows carry `sum` only, no `count`;
- `device.app` is `Health Relay 0.1`;
- the mindful session's value is `HKCategoryValueNotApplicable`, not `""`;
- the ECG is decimated to 128 Hz on the phone (256 samples at `rate: 128`
  instead of 1024 at 512); the trace a receiver keeps is the same.

cubby produces the same days, events and ownership from both bodies.
