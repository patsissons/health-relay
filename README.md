# Health Data Relay

Health Data Relay reads your health data on your phone and delivers it, in any
format, to destinations you choose: your own server, a dashboard, MQTT, email,
files or your calendar, when you tap Run or on a schedule. Nothing leaves the phone
except to those destinations.

**Docs and screenshots: [health-data-relay.lgtm.page](https://health-data-relay.lgtm.page)**

- **Exact incremental sync.** Days that changed are re-sent in full; a
  receiver ends up with what the phone has, deletions included.
- **One open schema.** [`docs/schema.md`](docs/schema.md), in Apple
  Health's own terms, versioned by name (`apple-push/1`).
- **Or any format.** [Templates](docs/templates.md) are text files that write JSON,
  CSV, Markdown, HTML, GPX or anything else.
- **Pipelines, not a service.** You add pipelines, each running when you tap
  Run or on a schedule, to destinations you choose; the app has no
  backend of its own.

## Platforms

| Directory | Platform | State |
|---|---|---|
| [`ios/`](ios/) | iPhone and iPad (iOS 17+), SwiftUI, HealthKit | v1 |
| [`ios/HealthDataRelayMac`](ios/HealthDataRelayMac) | Mac dashboard, reading a phone's server | v1 |
| [`ios/`](ios/) | Vision Pro | compiled, never run |
| `android/` | Android, Health Connect | later |

Each platform lives in its own directory and shares no code with the
others. What they share is the contract at the top level.

Where it stands against Health Auto Export, with the evidence for each feature: [`docs/parity-audit.md`](docs/parity-audit.md).

## The contract

- [`docs/schema.md`](docs/schema.md): the body every platform sends and
  every receiver accepts.
- [`docs/design.md`](docs/design.md): the behaviour every platform
  implements: which days are sent, batching, retries, triggers.
- [`docs/receivers.md`](docs/receivers.md): how to write a receiver.
- [`fixtures/`](fixtures/): `push-two-days.json`, the canonical example
  batch, and `empty-push.json`, the connection test. Both are in canonical
  JSON (`node tools/canonical.mjs --check fixtures/*.json`).
- [`tools/receiver.mjs`](tools/receiver.mjs): a throwaway local receiver
  (Node, no dependencies) that every platform is tested against.

The site (`site/`) is built from these docs; see [`site/README.md`](site/README.md).

A platform is done when, for the fixture's synthetic data, it emits
`fixtures/push-two-days.json` byte for byte, and its pushes are accepted by
`tools/receiver.mjs`.

```sh
node tools/receiver.mjs --token secret --out /tmp/pushes   # listens on :8787
curl -H 'Authorization: Bearer secret' --data-binary @fixtures/push-two-days.json http://localhost:8787/
```
