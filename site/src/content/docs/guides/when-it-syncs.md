---
title: When it syncs
description: What triggers a sync, what each one sends, and the limits iOS puts on background work.
sidebar:
  order: 1
---

Every sync is the same job, whatever started it: work out which days
changed, read them in full from Health, and send them to each destination
that is not paused.

## What starts a sync

- **Health records something new.** Health Relay asks iOS to wake it when
  data arrives: hourly at most for most types, daily for sleep, stand hours
  and mindful minutes. Many types arrive together, so wakes within five
  minutes of the last sync are skipped; their changes go with the next one.
- **Every morning.** The app asks iOS for a catch-up around 06:30.
- **Opening the app**, when the last successful sync is more than an hour
  old.
- **Sync now** on the Status tab, or pulling down to refresh.

iOS decides exactly when background work runs. It gives more time to
apps you use, and less in Low Power Mode.

:::caution[Turn on Background App Refresh]
Since iOS 27, an app can read Health in the background only when
**Background App Refresh** is on for it (Settings › General › Background
App Refresh). With it off, Health Relay still works, but only syncs while
you have it open.
:::

## Your iPhone must have been unlocked

iOS encrypts Health data while the phone is locked, and no app can read
it. Changes recorded overnight (sleep, for one) are sent after you first
unlock the phone in the morning. If a sync runs while the data is locked,
the Status tab says so and the next sync picks the days up; nothing is
lost.

## Which days a sync sends

- **Days with new data.** Health Relay tracks every type with a
  bookmark, so it knows exactly which days gained samples since the last
  sync, including a late watch sync for last Tuesday.
- **Today and yesterday**, every time.
- **The last 35 days, once a week.** iOS doesn't say which day a deleted
  sample belonged to, so a weekly sweep re-sends the recent past and
  deletions reach your destinations within a week.

Each day is sent **whole**: every type, every source, every sample the
phone has for it. A receiver can replace what it held for that day, so
edits and deletions on the phone land too. See
[Behaviour](/reference/behaviour/) for the exact rules.

## Re-send on demand

**Status › Re-send recent days** marks the last 7, 14 or 35 days to be sent
again and syncs. Use it after fixing a receiver, or after deleting
something in Health that you want gone everywhere now rather than at the
next weekly sweep.

## When a destination fails

Health Relay keeps each batch on disk until the destination accepts it,
and retries with growing gaps (1 minute, doubling, up to 6 hours). A
destination that refuses the token stops until you fix it; see
[Troubleshooting](/guides/troubleshooting/). Other destinations carry on
regardless.
