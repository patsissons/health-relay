---
title: Your first destination
description: Point Health Relay at an HTTP endpoint, test it and send your first days.
sidebar:
  order: 2
---

A **destination** is somewhere Health Relay sends your days. Today that is
any HTTP endpoint that accepts [the schema](/reference/schema/): your own
server, a self-hosted dashboard, a home automation webhook. You can add as
many as you like; each one gets every day, and they never hold each other
up.

## Add it

1. Open the **Destinations** tab and tap **+**.
2. Fill in:
   - **Name**: anything; it's how the app labels the destination.
   - **URL**: the endpoint, `https://` (or `http://` on your local
     network).
   - **Bearer token**: if the receiver gave you one. It is sent as
     `Authorization: Bearer <token>` and kept in the iPhone's Keychain.
   - **Extra headers**: only if your receiver needs them.
3. Tap **Save**.

## Test it

Open the destination and tap **Test**. Health Relay sends an empty push
(no days, no data) and shows the receiver's answer. Every receiver of the
schema answers it with success, so a green `200` means the URL and token
are right.

| You see | It means |
|---|---|
| `200` (or any `2xx`) | Ready. |
| `401` or `403` | The token is wrong or was revoked. |
| `400` | The endpoint answered, but it doesn't speak the schema. |
| `404` | Check the URL's path. |
| No answer | The phone can't reach the URL: a typo, a firewall, or a server that is down. |

## The first sync

Go back to **Status** and tap **Sync now**. A new destination first gets
the **last 30 days**, oldest first, one day per request, so the first useful
data lands within seconds and a failure costs one day, not thirty. After
that, each sync sends only the days that changed.

The destination's row reads **Up to date** when everything has been
delivered. Tap it to see each delivery, with the receiver's answer.

Older history is not sent. If your receiver needs years of history, import
a full Apple Health export into it once (Health app › your picture ›
Export All Health Data) and let Health Relay keep the recent days current.

## Try it without a server

The repository includes a small receiver that prints what it gets. On a
Mac on the same network as your phone:

```sh
node tools/receiver.mjs --token secret
```

Add a destination with URL `http://<your Mac's IP>:8787` and token `secret`.
Each push shows up in the terminal with its days and per-type counts. Add
`--out pushes` to save every body for a closer look.
