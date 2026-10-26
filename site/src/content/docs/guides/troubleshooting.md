---
title: Troubleshooting
description: What to do when days don't arrive.
sidebar:
  order: 4
---

Start with the destination's delivery log: **Status**, then tap the
destination. Each entry shows the HTTP status and the receiver's own
message.

## "Needs attention" with 401 or 403

The receiver doesn't accept the token any more. Get a new one from the
receiver, open the destination, paste it and tap **Test**. A passing test
clears the state and the waiting days go with the next sync.

## Deliveries fail with 400

The receiver answered, but refused the body. The log shows its message,
which usually says what it expected. Health Relay keeps those days waiting
and retries later, so once the receiver is fixed they arrive on their own
(or tap **Re-send recent days**).

## "Retrying" with no answer

The phone couldn't reach the receiver: no network, a typo in the URL, a
server that is down, or a firewall. Health Relay retries on its own with
growing gaps. **Test** checks the connection on demand.

An `http://` URL only works for addresses on your local network; anything
on the internet needs `https://`.

## Nothing arrived overnight

- **Sync automatically** is off by default; without it, days are sent
  only when you tap **Sync now**. Turn it on in the Status tab.
- Health data is locked until the phone is unlocked, so overnight changes
  are sent after the first unlock in the morning.
- Check that **Background App Refresh** is on for Health Relay, and that
  you haven't swiped the app away in the app switcher.
- Low Power Mode delays background work.

Opening the app syncs straight away if the last successful sync is more
than an hour old.

## A type never arrives

Open **Status › Data by type**. If the type is under **No data in 30
days**, either nothing recorded it or its permission is off: Settings ›
Health › Data Access & Devices › Health Relay, and turn it on.

## The receiver shows old values for a day

Re-send the day: **Status › Re-send recent days**. Each day is sent whole,
so the receiver ends up with exactly what the phone has.
