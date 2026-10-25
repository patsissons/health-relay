# Health Relay

Health Relay reads your health data on your phone and delivers each day,
exactly and incrementally, to destinations you choose: your own server, a
self-hosted dashboard, any HTTP endpoint that speaks its open schema.
Nothing leaves the phone except to those destinations.

- **Exact incremental sync.** Days that changed are re-sent in full; a
  receiver ends up with what the phone has, deletions included.
- **One open schema.** [`docs/schema.md`](docs/schema.md), in Apple
  Health's own terms, versioned by name (`apple-push/1`).
- **Destinations, not a service.** You add destinations; the app has no
  backend of its own.

## Platforms

| Directory | Platform | State |
|---|---|---|
| [`ios/`](ios/) | iPhone (iOS 17+), SwiftUI, HealthKit | v1 |
| `android/` | Android, Health Connect | later |

Each platform lives in its own directory and shares no code with the
others. What they share is the contract at the top level.

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

A platform is done when, for the fixture's synthetic data, it emits
`fixtures/push-two-days.json` byte for byte, and its pushes are accepted by
`tools/receiver.mjs`.

```sh
node tools/receiver.mjs --token secret --out /tmp/pushes   # listens on :8787
curl -H 'Authorization: Bearer secret' --data-binary @fixtures/push-two-days.json http://localhost:8787/
```
