---
title: The Status tab
description: What each part of the Status tab tells you, and the actions it offers.
sidebar:
  order: 2
---

The Status tab answers one question: has everything been delivered?

## Last sync

When the last sync ran and how it ended: **Up to date**, a count of
destinations that will retry, or why it stopped (for example, the phone
was locked). **Sync now** runs one immediately.

## Destinations

One row per destination:

| State | Meaning |
|---|---|
| **Up to date** | Every day it should have has been delivered. |
| **N days to send** | Days are waiting for the next sync. |
| **Retrying in …** | The last delivery failed (the receiver was down, or the network). It retries automatically; the message is the receiver's answer. |
| **Needs attention** | The receiver refused the token (`401` or `403`). Nothing is sent until you edit the destination or a Test passes. |
| **Paused** | You paused it. Days keep collecting and are sent when you resume. |

Tap a row to see its **deliveries**, newest first: the days in each
batch, when, the HTTP status, and what the receiver said. The days still
waiting are listed at the top.

## Re-send recent days

Sends the last 7, 14 or 35 days again to every destination, replacing what
they hold for those days with what the phone has now. See
[When it syncs](/guides/when-it-syncs/#re-send-on-demand).

## This iPhone's name

Destinations see this name with each delivery. Since iOS 16 apps can't
read the name you gave your phone, so set it here if you send more than one
phone to the same place.

## Data by type

Every type Health Relay reads, split into those with data in the last 30
days and those without. iOS never tells an app which permissions you
turned off, so a type you expected under **No data in 30 days** usually
means its switch is off in Settings › Health › Data Access & Devices ›
Health Relay.
