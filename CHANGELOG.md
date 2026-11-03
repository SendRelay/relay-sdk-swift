# Changelog

## 1.8.0 — 2026-11-03

- Keep looking for a rider and scheduled pickups ([dispatch strategies](https://docs.sendrelay.com.ng/tasks/keep-looking-and-scheduling)).
- `TaskStatus.scheduled` and `.searching`, and the `.dispatchStarted`, `.searching` and `.ridersNearby` task events, with `strategy`, `pickupAt`, `searchExpiresAt` and `ridersNearby`. `TaskTrackerState.searchExpiresAt` to count down to.
- `TaskEvent.rawStatus` holds the status exactly as the server sent it. `status` is nil for a status this version doesn't know, as before, so new Relay statuses (for tasks that keep searching for a rider) never stop an event from arriving. Switch over `TaskStatus` with a `default`.

## 1.7.0 — 2026-10-29

- First release, versioned with the other Relay app SDKs (they move together). Matches the shared SDK conformance suite (packages/sdks/conformance).
