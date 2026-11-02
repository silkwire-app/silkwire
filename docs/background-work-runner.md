# Awaited background runner

## Status and provenance

Private workspace AE860710 applies finished storage-preparation candidate 131BC4DA (f3ce59c), which already includes the installed 19387fd source changes and the earlier background engine/store. It does not include Claude's later panel/composer candidates and does not modify their files.

BackgroundWorkRunner connects the existing BackgroundWork models, admission limits, scoped executor contract and result identities to BackgroundWorkStorageSession's awaited off-main I/O. It is the asynchronous successor to the original synchronous BackgroundWorkEngine, not a Task wrapper around its synchronous Save closure. The original engine remains unchanged for compatibility/regression comparison; a new host integration must use the awaited runner, not attach the legacy store to UI.

This is an engine-to-storage integration candidate, **not yet the app/provider integration**. No live directory is selected, no real provider is contacted and no task is started by a Future card or by loading saved state. Nothing is installed.

## Ordering guarantees implemented here

- One runtime owner attaches to a storage session. A second runner, unowned saves and saves naming another runtime owner are refused. The owner token is never decoded from an agent message or a saved job.
- An explicit logical mutation mutex is held across physical saves, but never across provider or authorization awaits. Its waiters are FIFO in two lanes; this does not assume actor mailboxes are FIFO. Host calls are bounded to 64 waiters. A worker's own transitions (pending step, finished step, failure record) use a separate lane that is never refused and is normally served first; each worker has at most one outstanding, so that lane is bounded by `maxConcurrent`. Fairness bound: after `workerGrantsPerHostGrant` (4) consecutive worker grants that passed over a waiting host call, the oldest host call goes next. Continuously stepping workers therefore cannot hold an admission or a durable Stop indefinitely, and a worker transition waits behind at most one host call per turn. Generation checks remain an additional stale-write fence.
- Enqueue/start acknowledgements await their physical checkpoint. Pending step ID and lifetime attempt count must be saved before entering the executor. Completion must be saved before result publication or another step.
- Each physical commit is an awaited internal Task that does not inherit cooperative cancellation from its executor/caller. There is at most one such commit per logical mutex. This is not fire-and-forget: its real success/failure is awaited before state publication.
- Fresh authorization is checked both before recording a pending step and after that disk await. The executor must still recheck its operation fence and the real broker's current scope/ask-first rules before every operation, including after awaits.
- The dedicated background session identity, lifetime/slice limits, concurrency capacity, private-workspace exclusion and durable result-ID acknowledgement semantics remain explicit.

## Stop and shutdown

requestCancel(id) is a synchronous main-actor in-process fence. It invalidates the execution lease and signals cooperative cancellation before waiting on storage. The host then awaits cancel(id) to durably save the terminal state and must report failure honestly. A fence is not proof of a saved cancellation.

If Stop arrives while a completion write is physically in flight, the result stays suppressed. The accepted Stop is serialized after that write and saves cancellation, clearing the late result identity. A non-cooperative executor retains its physical concurrency/workspace slot until it actually returns, even after cancellation reaches disk.

Shutdown also fences immediately. It serializes a checkpoint after any in-flight save, preserving accepted Stop requests as cancelled and pausing other queued/running jobs for restart or exact-step reconciliation. A completion cannot escape an earlier accepted Stop merely because shutdown raced the separate cancel call.

Cancelling the caller of start while its start checkpoint is being saved does not launch the executor: the job is durably paused instead. Cancelling a control caller cannot erase the truth of a physical commit already underway.

Host-lane saturation is an explicit `BackgroundWorkError.busy` (nothing changed, try again), not an unbounded backlog and never a storage failure. A burst of host calls cannot stop a finished step from being saved. An immediate Stop fence remains in place if its durable cancel request cannot enter the full host lane; the host must show that it is not yet durably acknowledged and retry when the runner is no longer busy. An internal transition whose physical save fails still fences the runner closed to further execution.

## Failure, recovery and result delivery

Physical save failure or a generation conflict latches a runner failure fence, cancels workers, blocks new admissions and exposes no unconfirmed result. The disk session retains its writer lock. An exception after execution leaves the exact pending step for host reconciliation rather than replaying uncertain effects. A revoked grant after a pending save similarly pauses for reconciliation without entering the executor.

A job stopped mid-step keeps its uncertain `pendingStepID` while cancelled. `unresolvedItems` lists it (with paused-for-reconciliation work) once its physical worker has returned. `reconcileStopped(_:stepID:scope:evidence:)` records host-gathered broker evidence (`.performed(checkpoint:note:)` or `.notPerformed(note:)`) for the exact step and scope: the job stays cancelled, gets no result and never restarts, and only then becomes archivable.

Open validates current storage and preserves restart pauses, uncertain step IDs, lifetime attempts and result acknowledgements; it dispatches nothing. Reconciliation requires the exact step and matching runtime scope/limits. Even successful reconciliation does not automatically restart work. Transcript insertion must be durable and deduplicated by resultID before acknowledgement; this is a durable outbox, not cross-file exactly-once delivery magic.

## Bounded ledger and settled-item archive

The ledger is one bounded document (2 MiB, at most 256 items). Admission keeps every later save inside that bound instead of failing closed mid-work:

- Only a running item (its next checkpoint) or host reconciliation can grow an item. `start` reserves `maximumEncodedItemBytes` (48 KiB) for the item it admits, and every item keeps `transitionSlackBytes` (1 KiB) for host-written notes, pauses and step identities. `enqueue` counts a new queued item at its actual size plus that slack; it reserves growth when it is started.
- An applied outcome whose encoded item exceeds 48 KiB is refused like any other invalid outcome: that step is paused for reconciliation with its pending step retained, and the runner stays healthy. Raw field limits are unchanged; the encoded bound only matters for heavily escaped text (for example control characters).
- When an admission does not fit, settled, resolved items (completed with the result acknowledged, or cancelled with no uncertain step) whose workers have physically returned move to `background-work.archive.json`. If it still does not fit, the call throws `BackgroundWorkError.ledgerFull`, nothing changes, and `admissionHold` says why until an admission fits: `.unresolvedEvidence` when reconciling stopped steps would make room, otherwise `.ledgerFull`. Uncertain steps are never discarded or archived to make room. Running work keeps the room it reserved.
- A snapshot that still exceeds the document bound is refused by a pure size check before any I/O. That is reported as `ledgerFull` (the affected step pauses, for reconciliation if it had a pending step), not as a storage failure. Physical I/O failures still fence the runner closed exactly as before.
- The archive keeps the newest 256 entries that fit 2 MiB, dropping from the oldest archive pass first. It is history only: never loaded as ledger work, never startable, never a pending result. `item(_:)` and `archivedItems` still show archived items; acknowledging an archived result again is idempotent. `archiveSettledItems()` archives on demand.
- The archive is written before the ledger. A crash between the two leaves a settled item in both files; the ledger copy is authoritative and the next archive pass completes the move without duplicating it. BackgroundWorkDurabilityRegressionTests checks this with real SIGKILLs of a child process at each boundary of an archive pass and of a worker step, then reopens.

## Synthetic verification

BackgroundWorkRunnerTests exercises actual private checkpoint files with synthetic executors and transports. It covers automatic multi-step continuation without Pass, same-path reopen and result acknowledgement, a real NativeRoom foreground chat while pending-step I/O is deliberately held, immediate and durable Stop boundaries, Stop racing a completion save, cancellation during start, serialized reentrant admissions, single-runner ownership, delayed authorization, non-cooperative workspace exclusion, before/after-execution storage failure, grant revocation during disk waits, exact-step reconciliation, bounded slices, Stop/shutdown races and crash recovery.

The held-I/O tests establish scheduling and durability boundaries; they are not a rendered UI test, a real provider test or a performance benchmark. The host receipts and exact built revision determine passing status, not this document.

Documented checks:

```
swift Scripts/test.swift BackgroundWorkRunnerTests
swift Scripts/test.swift --reuse-core BackgroundWorkDurabilityRegressionTests
swift Scripts/test.swift --reuse-core BackgroundPersistenceResponsivenessTests
swift Scripts/test.swift --reuse-core BackgroundWorkStoreTests BackgroundWorkTests
swift Scripts/test.swift --reuse-core FutureNorthStarsEntryReviewTests FutureDrawerSaveReviewTests FutureTests
swift Scripts/test.swift --reuse-core BackgroundRoomIdentityReviewTests BackgroundRoomIsolationReviewTests BackgroundChatReviewTests
swift Scripts/test.swift --reuse-core RoomTests OpenFloorTests OpenFloorStopTests
swift Scripts/build.swift --staging
```

## Remaining app work

The app host must still provide dedicated real agent sessions and workspace admission, resource-budget reservations, current permission/revocation routing, result delivery into conversations and visible job controls; those paths require their own end-to-end start-once/chat-while-working/Stop/restart checks and independent review. Composer concurrency is a separate teammate-owned change. Preparing and privately testing this runner alone does not mean the installed agents can work after their chat turn ends.
