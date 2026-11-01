---
title: Pipelines
description: What a pipeline is, what its card tells you, and the actions it offers.
sidebar:
  order: 2
---

Everything Health Data Relay does is a **pipeline**, and each one shows as a card
on the Pipelines tab.

| Part | What it does | Today |
|---|---|---|
| **Transform** | The shape to send your days in | `Health Data Relay`, [the schema](/reference/schema/) |
| **Destination** | Where they go | An HTTP endpoint |
| **Trigger** | When it runs | Manual, when Health changes, or a schedule |

Each run sends the days that changed, whole.

Add as many as you like. Each keeps track of its own days, so running one
never runs another, and one failing never holds up another.

## When it runs

A **manual** card has a **Run** button. Tapping it runs that pipeline after
anything already running, and shows **Queued** until its turn. It also skips any
wait after a failed delivery, so it always tries.

A **scheduled** card counts down: **Next run in 3h 12m 05s**. Scheduled cards
don't need a Run button, but open one and **Run now** is there.

iOS decides when background work happens, so a countdown can't promise a run
time. At zero, the card says what it is waiting for:

| You see | It means |
|---|---|
| **Due, waiting for iOS** | It runs as soon as iOS gives it time. Opening the app runs it straight away. |
| **Due, unlock your iPhone** | iOS keeps Health data locked until you unlock the phone. |

A **when Health changes** card has no countdown: it runs as Health records new
data. See [When it runs](/guides/when-it-syncs/).

## How it stands

| State | Meaning |
|---|---|
| **Up to date** | Every day it should have has been delivered. |
| **N days to send** | Days are waiting for its next run. |
| **Retrying in …** | The last delivery failed (the receiver was down, or the network). It retries automatically; the message is the receiver's answer. |
| **Needs attention** | The receiver refused the token (`401` or `403`). Nothing is sent until you edit the pipeline or a Test passes. |
| **Paused** | You paused it. Days keep collecting and are sent when you resume. |

While it runs, the card shows what it is doing and how far through that step it
is: checking Health for changes, reading a day from Health, or sending it. The
bar below is the whole run. A first run reads and sends 30 days, so expect it to
take a minute or two.

## Open a card

Tap a card for **Run now**, its parts and **Edit**, and:

- **Deliveries**, newest first: the days in each batch, when, the HTTP status,
  and what the receiver said. The days still waiting are listed at the top.
- **Test**, which sends an empty push and shows the answer.
- **Re-send recent days**, which sends the last 7, 14 or 35 days again, replacing
  what the destination holds for those days with what the phone has now. See
  [Re-send on demand](/guides/when-it-syncs/#re-send-on-demand).
- **Paused** and **Remove pipeline**.

## Settings

**This iPhone's name**: destinations see this name with each delivery. Since
iOS 16 apps can't read the name you gave your phone, so set it here if you send
more than one phone to the same place.

**Data by type**: every type Health Data Relay reads, split into those with data in
the last 30 days and those without. iOS never tells an app which permissions you
turned off, so a type you expected under **No data in 30 days** usually means its
switch is off in Settings › Health › Data Access & Devices › Health Data Relay.

**Values by day**: today's or yesterday's value for every metric, read the way a
pipeline reads them, so you can compare them with the Health app. **Allow every
kind of data** there asks iOS for access to everything a pipeline can read.

## Templates

A pipeline's **Transform** can be a template, which decides what its output looks like. The
**Templates** tab lists the ones that come with the app: Metrics JSON v2, Metrics CSV, Health
Report Markdown, Health Summary HTML, Workout Routes GPX and Health Data Relay, which writes
the native format out field by field.

To write your own, tap **New template**, or copy a built-in and change it. **Preview** shows
what it writes on sample data, or on your own last three days, and a mistake shows its line
and column. Templates are text files, so you can share them and bring them in with
**Import a file**. [The template reference](https://github.com/patsissons/health-relay/blob/main/docs/templates.md)
lists everything a template can use.

## Exporting once

**Export**, at the top of the Pipelines screen, makes a file from a template and some dates without
setting up a pipeline. You can also choose a single workout. When it's done, share the file wherever
you like. Several files arrive as a ZIP.

For an export you repeat, make a pipeline with **Share sheet** as its destination. **Ask when run**,
under How much, asks for the dates each time you tap Run.

## Other destinations

**Files or cloud** saves each part as a file in a folder you pick, Dropbox or Google Drive, which can turn a CSV into a Sheet. Connect a cloud account in
**Settings › Connected accounts** first. iCloud Drive isn't supported yet, while Apple's rules on health data in iCloud are checked.

A template pipeline can send to **Email**, from your own mail server or a service like Resend without you doing
anything, or by composing in Mail, Gmail or another app with a tap. It can also send to **MQTT**, one message per part, or to **Calendar**, where each workout or other event
stays one event however often it runs. For **Home Assistant**, start from its preset: fill in your server's address and a
long-lived access token, and each metric appears as a sensor.
