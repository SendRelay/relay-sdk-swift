# Changelog

## 1.11.0 — 2026-11-14

- Version aligned with the app SDKs. Motorcycles are always `MOTORCYCLE`; the API no longer uses `BIKE`. No code change.

## 1.10.0 — 2026-11-09

- `TaskEvent.revision` and `RevisionGate`. Task events carry `revision` (the task's revision after the event, as on webhooks). The client delivers each task's events in order and once: a frame at or below the last revision it delivered for that task is dropped. Location updates and frames without a revision are always delivered.

## 1.9.0 — 2026-11-08

- New `TaskEventType` cases: `.stageArrived`, `.detailsUpdated` and `.riderUnassigned` (tasks created with `onRiderCancel: FIND_ANOTHER`), with `stageType` and `researchesLeft`. `TaskTracker` moves the task back to PENDING and clears the rider and ETA on `.riderUnassigned`.

## 1.8.0 — 2026-11-03

- Keep looking for a rider and scheduled pickups ([dispatch strategies](https://docs.sendrelay.com.ng/tasks/keep-looking-and-scheduling)).
- `TaskStatus.scheduled` and `.searching`, and the `.dispatchStarted`, `.searching` and `.ridersNearby` task events, with `strategy`, `pickupAt`, `searchExpiresAt` and `ridersNearby`. `TaskTrackerState.searchExpiresAt` to count down to.
- `TaskEvent.rawStatus` holds the status exactly as the server sent it. `status` is nil for a status this version doesn't know, as before, so new SendRelay statuses (for tasks that keep searching for a rider) never stop an event from arriving. Switch over `TaskStatus` with a `default`.

## 1.7.0 — 2026-10-29

- First release, versioned with the other SendRelay app SDKs (they move together). Matches the shared SDK conformance suite (packages/sdks/conformance).
