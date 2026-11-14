---
title: When it runs
description: What triggers a pipeline, what each run sends, and the limits iOS puts on background work.
sidebar:
  order: 1
---

Every run of the Health Data Relay transform is the same job, whatever started it:
work out which days changed, read them in full from Health, and send them to the
pipeline's destination. A template pipeline reads the range you set under **How
much** instead, such as since the last run, or the last 7 days.

## What starts a run

Each pipeline has its own trigger, set when you add or edit it.

Running a pipeline, by a tap or by itself, needs the trial or Health Data Relay
Full. After the trial, pipelines stay saved with their triggers and show a lock
instead of Run; choosing a plan resumes them as they were.

During the trial and on the free tier, everything reads the last 7 days: the 7
whole days before today, plus today so far. A longer range still runs and sends
the days in reach, and the pipeline's card says so. Full reads as far back as
Health goes, and when you unlock it, pipelines that send changed days catch up
on the last 35.

**Manual**, the default: only tapping **Run** or **Run now**. With every pipeline
manual, Health Data Relay doesn't ask iOS to wake it at all.

**A schedule**: every so many minutes, hours, days or weeks after its last run,
or every so many seconds while the app is open. It runs at the first chance once due: when iOS gives the app background time, or
straight away if the app is open. A failed delivery retries when its wait ends,
without waiting for the next interval.

**At a set time**: a time of day, on the days you choose. iOS decides when
background work happens, so this is the earliest it can run.

**When Health changes**: any of these.

- **Health records something new.** Health Data Relay asks iOS to wake it when
  data arrives: hourly at most for most types, daily for sleep, stand hours
  and mindful minutes. Many types arrive together, so wakes within five
  minutes of the last run are skipped; their changes go with the next one.
- **Every morning.** The app asks iOS for a catch-up around 06:30.
- **Opening the app**, when the last successful run is more than an hour
  old.

iOS decides exactly when background work runs. It gives more time to
apps you use, and less in Low Power Mode. A run started in the background stops
starting new work after about 25 seconds, and the next one carries on.

:::caution[Turn on Background App Refresh]
Since iOS 27, an app can read Health in the background only when
**Background App Refresh** is on for it (Settings › General › Background
App Refresh). With it off, pipelines only run while you have the app open.
:::

## Your iPhone must have been unlocked

iOS encrypts Health data while the phone is locked, and no app can read
it. Changes recorded overnight (sleep, for one) are sent after you first
unlock the phone in the morning. If a run comes while the data is locked, its
card says so and the next run picks the days up; nothing is lost.

## Which days a run sends

This is for the Health Data Relay transform, and templates set to **Days that changed**.

- **Days with new data.** Health Data Relay tracks every type with a
  bookmark, so it knows exactly which days gained samples since the last
  run, including a late watch sync for last Tuesday. A pipeline left unused
  for months still gets the days that changed while it was idle.
- **Today and yesterday**, every time.
- **The last 35 days, once a week.** iOS doesn't say which day a deleted
  sample belonged to, so a weekly sweep re-sends the recent past and
  deletions reach your destinations within a week.

Each day is sent **whole**: every type, every source, every sample the
phone has for it. A receiver can replace what it held for that day, so
edits and deletions on the phone land too. See
[Behaviour](/reference/behaviour/) for the exact rules.

## Re-send on demand

Open a pipeline and tap **Re-send recent days** to send the last 7, 14 or 35
days again. Use it after fixing a receiver, or after deleting
something in Health that you want gone everywhere now rather than at the
next weekly sweep.

## When a destination fails

Health Data Relay keeps each batch on disk until the destination accepts it,
and retries with growing gaps (1 minute, doubling, up to 6 hours). A
destination that refuses the token stops until you fix it; see
[Troubleshooting](/guides/troubleshooting/). Other destinations carry on
regardless.
