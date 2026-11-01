# Templates

A template turns what a pipeline reads from Health into the text it delivers. A
template is one text file: a small header, then a body in a subset of
[Liquid](https://shopify.github.io/liquid/). This document is the contract:
what's here keeps working across versions.

```liquid
---
name: Daily steps
format: csv
data: [metrics]
partition: day
filename: "steps-{{ partition.key }}.csv"
---
date,steps,source
{% for p in metrics.step_count.data %}{{ p.date | date: '%Y-%m-%d' }},{{ p.qty }},{{ p.source }}
{% endfor %}
```

## Header

| Key | Meaning |
|---|---|
| `name` | Required. What the app shows. |
| `description` | One line about it. |
| `format` | `json`, `csv`, `markdown`, `html`, `xml`, `gpx` or `text`. Defaults to `text`. |
| `data` | The sections it needs: `metrics`, `workouts`, `symptoms`, `ecg`, `heart_rate_notifications`, `state_of_mind`, `cycle_tracking`, `medications`. |
| `partition` | Runs the template once per `none`, `day`, `week`, `month`, `year`, `metric`, `section` or `workout`, each producing one part. Defaults to `none`. |
| `filename` | A template for each part's name. `/` becomes `-`, so a name can't leave its folder. |
| `content_type` | Overrides the format's media type. |

An unknown key is an error, so a typo doesn't pass silently.

## Safe by format

`{{ value }}` always produces something valid where it's written:

| Format | What `{{ value }}` does |
|---|---|
| `json` | Writes a JSON value: text gets its own quotes, a list or object is written whole, a missing value is `null`. |
| `csv` | Quotes a field that needs it. Text starting with `=`, `+`, `-` or `@` also gets a leading `'`, so a spreadsheet doesn't run it as a formula. Numbers are left alone. |
| `html`, `xml`, `gpx` | Escapes `&`, `<`, `>`, `"` and `'`. |
| `markdown` | Escapes `\` and `|` and flattens line breaks, so a table stays a table. |
| `text` | Writes it as it is. |

`{{ value | raw }}` opts out, for example inside quotes you wrote yourself in JSON:
`"id-{{ id | raw }}"`.

`json` output is checked as it's written, and `xml` and `gpx` have their tags
checked. Output that doesn't parse fails the run rather than sending bad data.

## Data

| Variable | What it is |
|---|---|
| `export` | `start`, `end`, `generated_at`, `format`, `time_zone`, `grouping`, `device.name`, `device.model`, `device.os`, `device.app` |
| `partition` | `kind`, `key`, `start`, `end`, `section`, `metric` |
| `metrics` | By name, `metrics.step_count`. In a loop, the metrics that have data. |
| `workouts` | Each workout, oldest first. |
| `workout` | The current one, in a `workout` partition. |
| `symptoms` | `name`, `severity`, `source`, `start`, `end`, `userEntered`, `cycleStart` |
| `cycle_tracking`, `heart_rate_notifications` | `name`, `value` when the type has values, `source`, `start`, `end`, `userEntered`, `cycleStart` |
| `ecg` | `start`, `end`, `classification`, `averageHeartRate`, `samplingFrequency`, `numberOfVoltageMeasurements`, `source`, `voltageMeasurements` (`date`, `voltage`, `units`) |
| `state_of_mind` | `kind`, `valence`, `valenceClassification`, `labels`, `associations`, `source`, `start`, `end` |
| `medications` | `name`, `nickname`, `status`, `quantity`, `scheduledQuantity`, `scheduledDate`, `unit`, `source`, `start`, `end` |

A metric has `name`, `title`, `group`, `units` and `data`, its points. What's on
a point depends on the metric and whether it's summarized:

| Point | Fields |
|---|---|
| Most metrics, summarized | `date`, `qty`, `source` |
| Heart rate, summarized | `date`, `Min`, `Avg`, `Max` (also `min`, `avg`, `max`), and no `source` |
| Blood pressure | `date`, `systolic`, `diastolic`, `source` |
| Sleep, summarized | `date`, `totalSleep`, `core`, `deep`, `rem`, `awake`, `asleep`, `inBed`, `inBedStart`, `inBedEnd`, `sleepStart`, `sleepEnd`, `source` |
| Unsummarized | `date`, `start`, `end`, `qty`, `source`; heart rate adds `Min`, `Avg`, `Max`, `context`; heart rate variability can add `heartbeatSeries`; sleep has `value`, `startDate`, `endDate` |

`source` lists several sources separated by `|`. Every point also has `units`.

A workout has `id`, `name`, `activity_type`, `start`, `end`, `duration`,
`isIndoor`, `location`, `source.name`, `source.identifier`, `metadata`,
`has_route`, `route` and `statistics`, and any one statistic by name, such as
`workout.activeEnergy.sum`. A route point has `timestamp`, `latitude`,
`longitude`, `altitude`, `course`, `courseAccuracy`, `speed`, `speedAccuracy`,
`horizontalAccuracy` and `verticalAccuracy`.

Dates write as `2026-10-24 17:00:00 -0700` unless you use `date` or `iso8601`.
Writing `{{ point }}` or `{{ metric }}` in JSON writes the whole thing.

## Language

**Tags:** `if`/`elsif`/`else`, `unless`, `case`/`when`, `for` with `limit`,
`offset`, `reversed` and `else`, `break`, `continue`, `assign`, `capture`, `raw`,
`comment`, and whitespace control with `{%-` and `-%}`.

There's no `include` or `render`. A template can't reach the network, other files
or anything but the data it's given.

**`forloop`:** `index`, `index0`, `first` and `last` always work. `length`, `rindex`
and `rindex0` need the whole list in hand, so they're empty when walking Health data
and work on lists you've made with a filter.

**Filters:** `abs`, `append`, `at_least`, `at_most`, `capitalize`, `ceil`, `compact`,
`concat`, `date`, `default`, `divided_by`, `downcase`, `escape`, `escape_once`, `first`,
`floor`, `group_by`, `iso8601`, `join`, `json`, `last`, `lstrip`, `map`, `minus`,
`modulo`, `newline_to_br`, `plus`, `prepend`, `raw`, `remove`, `remove_first`, `replace`,
`replace_first`, `reverse`, `round`, `rstrip`, `size`, `slice`, `sort`, `sort_natural`,
`split`, `strip`, `strip_html`, `strip_newlines`, `sum`, `times`, `truncate`,
`truncatewords`, `uniq`, `upcase`, `url_decode`, `url_encode`, `where`.

**`date`** takes strftime conversions: `%Y %y %m %d %e %j %H %I %M %S %L %p %P %z %:z
%Z %A %a %B %b %h %u %w %s %F %T %D %%`.

Numbers write the way JavaScript writes them, so `{{ 3 | divided_by: 2 }}` is `1.5`.
Only `nil` and `false` are false; `0` and `""` are true, as in all Liquid.

## Large data

A loop reads Health a page at a time and output goes straight to disk, so a template
can write far more than fits in memory. A week of one reading a second is about 600,000
rows. Anything that needs every row at once loads them: `sort`, `sort_natural`, `map`,
`where`, `group_by`, `join`, `size`, `last`, `uniq`, `reverse` and looping with `reversed`.
Those are capped at 500,000 rows, and a list past that fails its run with a message.

A run has limits on output size, loop rows and time. A template that hits one fails its
own run, with a line number, and nothing else is affected.

## Checking the language

`fixtures/templates/conformance.json` holds cases run through both this engine and
[liquidjs](https://liquidjs.com), `npm test` in `tools/conformance`. A case passing
in both means the subset agrees with a real Liquid implementation.
