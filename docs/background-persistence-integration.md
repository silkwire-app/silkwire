# Off-main background checkpoint persistence: preparation, not app integration

## Scope and provenance

Private candidate 131BC4DA starts from the verified b15af04 bundle and applies E8DED860 (engine plus durable store) and 85D47CD5 (the installed 19387fd source changes) before its own edits. It does not alter the running app, the connected source, any live library, sign-ins or providers. Claude owns the separate drawer/blank-editor presentation changes; those are not included here.

This change prepares the storage boundary needed by an asynchronous background-work host. It does **not** connect BackgroundWorkEngine to the installed app, implement provider sessions or remove the need for conversation turns.

## What changes

- BackgroundWorkEngine exposes its existing snapshot invariants through a pure, nonisolated validator. Both primary and recovery documents use that validation before any recovery rewrite.
- A private BackgroundWorkDisk implementation retains the original descriptor-relative path checks, single-writer flock, restrictive permissions, bounded documents, atomic replacement, fsync/F_FULLFSYNC and recovery copy.
- BackgroundWorkStorageSession owns that backend on a non-main actor. Opening, reading and saving restart pauses happen on a detached utility task; awaited saves perform their physical I/O on the storage actor, not on the main actor.
- A confirmed State contains the snapshot, a session-local generation and a sticky physical-storage-failure flag. save(snapshot, basedOn: generation) advances the generation only after the physical commit succeeds.
- Actor mailboxes are not FIFO. Two snapshots based on one generation cannot silently overwrite each other: the stale write is rejected. The host must serialize logical mutations and must not treat an arbitrary scheduling order as its task order.
- Recovery changes queued/running jobs into paused restart/reconciliation states before returning the session. Pending step IDs, lifetime attempts, terminal results and acknowledgement identities are preserved. Loading storage dispatches no work.

## Compatibility and remaining blocker

The original BackgroundWorkStore facade remains for existing regression fixtures. **Its engine Save contract is still synchronous and must not be attached to a live main-actor UI.** This candidate deliberately does not pretend that wrapping synchronous Save in Task, a semaphore or dispatch-and-forget creates safe asynchronous durability.

The next engine change must explicitly serialize asynchronous state transitions and await this session. The app host must still supply the existing private directory, runtime admission permits, dedicated background agent sessions, current broker checks, budgets and deduplicated result delivery. A Future card or priority is not permission to start work.

## Cancellation and physical outcomes

Cancellation checked before save entry prevents that save without poisoning storage. Cancellation arriving during a synchronous physical commit cannot roll back a rename or fsync. The session returns the real commit outcome instead of throwing a misleading post-commit CancellationError. The storage owner and kernel writer lock survive until the actual I/O ends; cancellation must not admit a competing writer.

Open checks cancellation before spawning its utility task. Once opening/recovery is underway it awaits the real result rather than claiming the physical work was cancelled. This is a bounded local operation, not a provider or job restart mechanism.

An exception after rename can leave new bytes visible without a confirmed durable outcome. The session then latches storageFailed, does not advance its confirmed snapshot/generation, and refuses further saves. Host reconciliation is required; never infer a safe replay from an error or cancelled caller.

## Required asynchronous engine/host ordering

1. Keep a single logical mutation queue per ledger. Read the confirmed generation and await each save; do not launch unbounded snapshot-writing Tasks.
2. Establish cancellation/revocation fences immediately, before awaiting storage. A subsequent main-actor action must remain possible while a write is delayed.
3. Persist and await the exact pending step identity and attempt count before invoking an executor. After every await, revalidate task lease, scope, cancellation and current broker permission.
4. Persist and await a completed step before advancing or publishing a result. Retain physical worker/concurrency ownership until both executor and required storage operations really finish, including non-cooperative cancellation.
5. Handle a generation conflict as a serialization/reconciliation event, not a blind retry of an old snapshot. Handle physical storage failure as fail-closed, not a successful result.
6. Resume uncertain steps only from independent broker evidence. Preserve dedicated background session identity and result-ID deduplication/acknowledgement across restart. No automatic replay merely because a ledger loaded.
7. Integrate with actual app sessions, composer availability and result delivery, then test start-once/continue-without-Pass/chat-while-working/Stop/restart end to end. None of those live integration claims is established by this storage-only suite.

## Verification plan and limits

BackgroundPersistenceResponsivenessTests uses private temporary directories, real local file operations and a bounded fault gate that holds a physical write. It checks main-actor availability while saves and restart-opening writes are held, retained writer exclusion after cancellation, actual commit outcomes, stale-generation rejection, recovery copies, pre-write cancellation, malformed snapshot rejection, restart reconciliation, result identities and sticky storage failure before/after rename. This is a deterministic scheduling/I/O test, not a rendered UI or interactive performance measurement.

The existing BackgroundWorkStoreTests and BackgroundWorkTests remain unchanged and exercise the legacy adapter plus shared backend. Future/room regression suites and a private Staging build check source compatibility. The host receipt, exact head and real exit codes are the authority for results; this document alone asserts no passing execution.

Documented checks:

```
swift Scripts/test.swift BackgroundPersistenceResponsivenessTests
swift Scripts/test.swift --reuse-core BackgroundWorkStoreTests
swift Scripts/test.swift --reuse-core BackgroundWorkTests
swift Scripts/test.swift --reuse-core FutureNorthStarsEntryReviewTests FutureDrawerSaveReviewTests FutureTests
swift Scripts/test.swift --reuse-core RoomTests OpenFloorTests OpenFloorStopTests
swift Scripts/build.swift --staging
```

No installation, live provider calls, stable-app access, sign-in changes or live-data migration are included.
