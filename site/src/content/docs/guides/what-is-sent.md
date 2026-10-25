---
title: What is sent
description: The Health data Health Relay reads, what leaves the phone, and what never does.
sidebar:
  order: 3
---

## Your data goes only where you send it

Health Relay has no server, account or analytics. It reads Health on your
phone and sends days to the destinations you added, and nothing anywhere
else. Tokens stay in the iPhone's Keychain. The queue of unsent batches
lives in the app's own storage and is not backed up.

Never read or sent: clinical records, your name, your date of birth, or
anything not listed below.

## What a day carries

For each day it sends, Health Relay includes everything the phone has for
that day:

- **Daily statistics per source** (iPhone, Watch, scale, apps), so a
  receiver can tell the watch's step count from the phone's:
  - activity: steps, walking and running distance, cycling and rowing,
    active and resting energy, exercise and stand minutes, flights climbed,
    time in daylight, falls, physical effort
  - heart: heart rate (average, minimum, maximum), resting and walking
    heart rate, heart rate variability, recovery, VO2 max, respiratory rate,
    blood oxygen
  - mobility: walking speed, step length, asymmetry, double support,
    steadiness, stair speeds, six-minute walk
  - body: weight, body fat, lean mass, BMI, height
  - nutrition: energy, macronutrients, water, caffeine, and every vitamin
    and mineral Health records
- **Individual samples** where the day needs each one: sleep stages, stand
  hours, mindful sessions, symptoms, blood pressure readings, sound levels,
  wrist temperature, workout effort scores.
- **Workouts** with their energy, distance, heart rate and every point of
  their route.
- **Activity ring summaries**: the stand hours the ring counted and your
  Move goal.
- **ECG recordings**: classification, average heart rate and the trace,
  averaged to 128 samples a second.

The exact format is [the schema](/reference/schema/). It uses Apple
Health's own names, the same ones as in a Health export, so a receiver that
already reads `export.xml` needs little new code.

## How much data

Heart rate and the other frequent measurements travel as daily statistics,
not sample by sample, so a day is small: a few kilobytes of JSON, and a few
tens of kilobytes with a GPS workout (every route point is included).
Batches hold up to seven days and are split above about 1 MB, so syncing
is light on mobile data.
