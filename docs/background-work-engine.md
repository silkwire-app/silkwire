# Background work engine — private candidate integration contract

Status: engine and synthetic fixtures only. The running app is unchanged. This is not an end-to-end backgrounding release, an installation plan, a new permission or a replacement for the computer-control task system.

## Ownership boundary

`BackgroundWorkEngine` owns asynchronous private-work slices, checkpoints, cancellation fences and a result outbox. It does not own foreground `NativeRoom` turns. `start` returns promptly; checkpoint steps continue without another conversation turn or Pass. Suspended async steps do not prevent an independent foreground room from replying.

The existing single-active-turn room gate still needs the room-side integration. Do not just remove it: current provider callbacks must never be routed into a different task or chat.

`WorkspaceTaskBoard` remains the assignment/overlap coordinator, not permission. Existing `ComputerControlCenter.AgentTask` tasks concern a different, real-computer lane. Do not automatically import or restart those tasks, especially cancelled install tasks.

## Host adapter required before real use

1. Own exactly one engine and one writer per saved ledger. The engine is serialized within one process, not across independent apps/processes. It also permits only one physical worker per private workspace, even while a cancelled executor is winding down. The host must prevent older app copies or concurrent writers from reopening this ledger for execution.
2. Keep snapshots outside agent-writable worktrees. Supply a synchronous, non-reentrant `save` implementation with atomic durable replacement, safe canonical paths, restrictive permissions, schema/size validation and recovery backups. It must throw on failure rather than claim success. The engine validates a 2 MB encoded limit and never clears invalid saved state. The tests use only synthetic temporary files.
3. A saved item, goal, checkpoint, memory note or Future priority is never authority. Construct a runtime `BackgroundWorkPermit` from current host-approved scope. Resolve its Project, originating conversation, private workspace, assigned owner and exact source base revision independently. Revalidate actual current broker permissions at every operation; do not restore grants or credentials from task data.
4. Allocate a genuinely separate provider session/identity using `sessionID`, not the foreground chat identity. The stable session key allows continuity, not replay of pending provider operations. The engine rejects known originating-room/session collisions in restored data; the adapter must also exclude all other live foreground identities.
5. Supply an async scoped executor. It must check `context.mayPerformOperation()` immediately before each broker operation and after awaits, and pass through the existing sandbox, ask-first, revocation, operation timeout and resource controls. It must never turn an engine task into unsandboxed computer control or install/deploy authority. Heavy synchronous CPU work must not run on the main actor.
6. Observe snapshots for a small work-status UI. Do not create a placeholder conversation reply or put `activeWorkerCount` into the room's Send/busy gate. A storage fault must be shown as a stopped/blocked work system, not a provider disconnect or success.
7. Post completed results using the saved `resultID` as a transcript deduplication key, then call `acknowledgeResult`. The outbox survives restarts. It is not an exactly-once guarantee across independent ledger/transcript files without host deduplication.

## Recovery and cancellation

Every step is saved with a unique pending-step ID and consumed lifetime attempt before execution. A completed checkpoint is saved before another step begins. A throw/timeout or crash at an uncertain boundary keeps that ID and requires host reconciliation against independently recorded broker evidence. An agent saying "done" is not evidence. Never blindly rerun an uncertain external/provider action.

Loading a snapshot starts nothing. Clean queued/running boundaries become restart-paused; pending boundaries become reconciliation-paused. The host may automatically re-admit clean, already-approved private work only after fresh grant/resource/session checks. It must not revive cancelled/completed work or turn an ambiguous step into a replay. `reconcile` names the exact pending ID and saves a verified outcome without starting more work.

Slice exhaustion pauses with a checkpoint. Further host admission can continue a slice but cannot expand or reset the saved lifetime limit. Provider disconnect states are not involved.

Cancellation is saved before signalling Task cancellation. Old callbacks lose their operation fence and cannot publish late success. A non-cooperative executor retains its concurrency slot until it actually returns: cancelling is not proof that a subprocess/provider stopped. The adapter must stop the underlying operation, enforce timeouts, and reconcile any uncertain accounting. Shutdown similarly invalidates execution fences. If cancellation cannot be saved, the engine reports storage failure, fences all in-process operations and does not claim a durable cancellation; reopening remains paused for recovery.

No automatic periodic polling, paid-API fallback, budget reset, real-time deadline enforcement or model-selection policy is introduced here. Existing 900-second broker command limits and any future resource governor must be enforced by the adapter. The separate offline WorkBudget candidate is not silently integrated by this change.

## Review checks

- `swift Scripts/test.swift BackgroundWorkTests`
- `swift Scripts/test.swift --reuse-core OpenFloorTests`
- `swift Scripts/build.swift`

Fixtures cover save-before-execute, automatic continuation, foreground NativeRoom chat during suspended engine work, atomic synthetic disk reopen, result acknowledgement, cancellation during permission lookup, non-cooperative cancellation, uncertain-step reconciliation, crash recovery, scope/step limits, permission revocation, storage faults and parallel session isolation. They do not claim live-provider, real build-process cancellation, UI, full app restart, library migration or installation acceptance.
