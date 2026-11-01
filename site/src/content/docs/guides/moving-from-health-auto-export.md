---
title: Moving from Health Auto Export
description: How to set up the same exports in Health Data Relay.
---

If you use [Health Auto Export](https://www.healthyapps.dev/apps/health-auto-export/) today, here's how its pieces map onto Health Data Relay. The two apps aren't related.

## Bring over an automation

If you have an automation link (`com.HealthExport://automation?...`), copy it. In Health Data Relay, tap **+**, then **Use a copied link**. You'll see the settings and where the data would go before anything is saved, along with anything that couldn't be carried over.

## How things map

| Health Auto Export | Health Data Relay |
|---|---|
| Automation | A pipeline, shown as a card |
| Data type | **Data**, under What it reads. One pipeline can carry several. |
| JSON v2 | The **Metrics JSON v2** template |
| Markdown | The **Health Report Markdown** template |
| GPX | The **Workout Routes GPX** template |
| REST API | A **REST API** destination |
| Time grouping | **Grouping** |
| Summarize data off | Grouping: **Every sample** |
| Default date range, Today, Yesterday | **How much** |
| Since Last Sync | **Since the last run** |
| Manual Export | **Export**, at the top of the Pipelines screen |
| MCP server | **Settings › Server** |

## What's different

**Receivers that read JSON v2 should mostly just work.** Its fields and nesting follow what that app writes, but four sections are based on its documentation rather than real output: heart rate notifications, state of mind, cycle tracking and medications. Check those if you use them.

**The legacy v1 format and its CSV layout aren't supported.** A link asking for v1 is refused, since a receiver expecting v1 couldn't read v2. CSV here has its own columns.

**Deletions can reach your receiver.** With **Days that changed**, a whole day is sent again when anything in it changes, so a receiver ends up with what your iPhone has.

**You can change the output.** Every format is a template you can copy and edit.

**iCloud Drive isn't supported yet**, while Apple's rules on health data in iCloud are checked. Use a folder on your iPhone or another destination.

**It's free**, with no account.

## Both are limited by iOS

iOS decides when background work runs, and keeps Health data locked while your iPhone is locked. A schedule is the earliest something can run, in any app.
