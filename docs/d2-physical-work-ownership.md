# D2 ownership component and integration contract

Status: **component delivered; D2 is NOT established as fixed in the app.**
This change adds source, tests, a focused test script and this contract. It makes
no runner, storage, model, transport, UI or existing script changes. Existing
foreground/background entry points do not call this component yet.

Baseline: `16fac7fd86d305cff048b90c18f0d5455121365b`.

## Authority and storage scope

`PhysicalWorkOwnership` is a synchronous, Sendable host component. All disk work
must run on a dedicated storage executor, outside the main actor. Its operations
take a short nonblocking `flock` on one permanent file, read/validate the ledger,
and commit a replacement with file `fsync`, macOS `F_FULLFSYNC`, atomic `renameat`
and directory `fsync`. Separate opens serialize concurrent callers in the same
process as well as independent processes. No lock is held during execution.

The app host must provision **one authoritative existing directory**, owned by the
current effective UID, mode 0700, on a local filesystem supporting those sync
operations. Pass the SAME directory and capacity to every conversation, foreground
build, background runner and cooperating helper process. No conversation/project
UUID belongs in this directory's path. No default app-library location is selected
by the component. The private tests supply isolated temporary directories.

An actual application-global policy must use a shared host-selected location
across every participating app instance, helper and library/profile that can touch
the same workspace. Giving each library, process or conversation a different
registry creates separate limits and violates this contract. The directory must
be outside agent-writable workspaces and outside provider sandbox write grants.
It is cooperative coordination among trusted same-UID hosts, not protection
against malicious same-UID code. Cross-OS-account coordination would require a
trusted shared service and is not provided.

Capacity (1...256) is persisted at first initialization. A differing caller fails
with `configurationMismatch`; it cannot quietly raise or lower capacity. Changing
capacity or migrating the directory requires a host-managed quiescent migration,
preserving active reservations and operation history. Never delete/rotate/replace
`ownership.lock`, `ownership.json` or the directory to clear a failure. In particular,
lock-file unlink/replacement breaks advisory locking. Interrupted first bootstrap
(lock exists, state absent) requires explicit host recovery; reopening fails closed.

## Workspace and worker unit

`reserve(workspace:owner:operationID:)` resolves an EXISTING directory via
`realpath`, opens it, and records both canonical path and device/inode identity.
Same identity OR same canonical path conflicts while a reservation is active.
This catches symlink, dot, parent-component and case aliases, and conservatively
retains a path fence when a directory is replaced. Registry-directory aliases also
resolve to the same files. Missing workspaces fail admission.

Callers resolve the app's workspace UUID to its actual authorized filesystem root;
conversation-local workspace/folder IDs are not ownership keys. Callers must keep
that root stable from resolution through physical completion. Concurrent namespace
mutation (renaming, replacing or retargeting roots/symlinks) is outside this API's
guarantee and must be prevented by the host; the API does not hold a workspace file
descriptor throughout execution. Distinct nested roots, separate Git worktrees
and shared external output/cache paths are not automatically overlapping roots.
The host must choose one common canonical conflict root for such work or implement
additional resource claims. Do not choose a broader root differently per caller.

One reservation = one top-level physical executor with one exclusive conflict
root. It atomically consumes one shared slot AND that workspace; there is no
partial acquisition or wait while holding only one resource. Internal sequential
build/test steps use that same reservation. Delegated operations that are part of
the same physical executor inherit it and must join before release. They must not
recursively acquire another slot. Independently concurrent top-level executors
each need a slot; sharing a lease to create several independent workers violates
the limit. The limit counts executor units, not compiler subprocesses or CPU cores.

> **Superseded for trusted private workspaces** (see `docs/safe-parallel-ownership.md`):
> a non-inherited trusted begin is keyed by its own private run root, because the Builder
> only reads the source. Exclusive machine-wide operations use `exclusiveOperation`.

For source-to-private-worktree builds, use the stable canonical granted source as
the conservative conflict root from preparation through final evidence collection.
Both foreground and background jobs derived from that source must follow this
policy, even if their generated worktree paths differ. Operations on an already
independently granted worktree must use the same host mapping to that conflict
root. Resolve this policy centrally; bypassing it via a private path is invalid.

## Lifecycle, cancellation and uncertain outcomes

1. Persist the logical operation/pending-step UUID in the caller's task record.
   Perform fresh host authorization. Reserve using that UUID, the canonical
   conflict root, conversation UUID and `.foregroundBuild`/`.backgroundJob`.
   Kind and conversation are diagnostics; neither partitions the limit.
2. Retain the opaque `Lease` in an executor owner that outlives UI/runner teardown.
   Persist `beginExecution(lease)` BEFORE spawning, sending, connecting a provider
   that can act, invoking a broker, editing, or starting preparation commands.
   No physical effect is allowed when either operation throws. Stop and dispatch
   must be serialized by that executor owner: do not allow a Stop arriving between
   this commit and dispatch to launch untracked work. Recheck cancellation and
   fresh authorization at dispatch and at every broker operation after awaits.
3. Before `beginExecution` only, `abandonBeforeExecution` releases a reservation
   known never to have dispatched. `requestStop` also fences beginExecution for a
   still-reserved lease. Once beginExecution commits, conservative joining is
   required even if spawning subsequently reports an error.
4. On Stop, synchronously fence the host's future operations, request actual
   cancellation, and durably record `requestStop(lease)` off the main actor.
   Surface a durability error. Neither successful Stop, a terminal UI receipt,
   `Task.cancel()`, a thrown error nor disappearance of a conversation releases
   anything. Finish/Stop/reconciliation deliberately ignore task cancellation so
   they can complete during teardown.
5. Join the ENTIRE physical executor, including process groups/descendants,
   provider requests, broker/delegated callbacks, preparation/finalization commands
   and asynchronous Stop tasks. Only then call `finishAfterPhysicalExit` with a
   bounded host evidence reference. Its argument is a TRUSTED CALLER ATTESTATION,
   not proof validated by this generic registry. A process leader exit, signal
   delivery, pipe closure or model-generated “done” alone does not prove all this.
6. If physical exit cannot be verified, call `markUncertain` when possible and
   retain the lease. Even if this write fails, the prior durable reservation stays
   fenced. There is no TTL, heartbeat expiry, `deinit`, PID-liveness reclaim,
   shutdown reset or automatic recovery that can authorize replay. A crash in
   reserved, executing or Stop-requested state still holds workspace AND capacity.

A cancellation arriving after an admission commit does not cause `reserve` to
throw away its lease. Check cancellation on receipt, then abandon before begin or
join after begin. If persistence throws at any boundary, physical dispatch must
not proceed; the durable result may be uncertain. Inspect by operation UUID and
reconcile rather than inventing a new UUID to retry.

`reconcileAfterPhysicalExit(expectedRecord:evidence:)` is an explicit privileged
host recovery operation. Obtain a fresh `snapshot`, independently establish that
no local/remote physical work survives and review the pending outcome, then pass
the exact record and an audit/evidence reference. A changed record fails the
comparison. Mere owner PID absence, PID reuse, elapsed time or Stop ACK is never
sufficient evidence. The API trusts the host's verification; do not expose this
method as an agent tool or an automatic restart hook.

Finished/abandoned records release resources but remain durable tombstones.
The same operation UUID is rejected forever, including after explicit recovery.
A different UUID is permitted only after separate host authorization and outcome
reconciliation; ownership is not a permission grant. Preserve existing background
`pendingStepID`/reconciliation fences and foreground receipt checks. Even a proved
physical exit can leave an uncertain operation outcome that must not be replayed.
Tombstones are bounded by 10,000 records and a 4 MiB ledger: exhaustion fails closed.
No automatic history compaction/forgetting is implemented.

## Required caller changes (owned by the integration work)

| Existing boundary | Required change |
| --- | --- |
| Application host / library opening | Provision one registry, configure one persisted global capacity, inject access into all execution owners and helper launch arguments. Recover fail-closed startup errors visibly. Keep storage off the main actor. |
| `BackgroundWorkRunner.open/start/run` | Inject the shared registry/coordinator. Resolve the real conflict root; reserve before physical dispatch after authorization/pending-step durability. Store the lease with the physical worker, not a conversation lifecycle token. Existing `workers.count < maxConcurrent` and workspace UUID checks can be fairness prefilters only. They cannot establish global admission. Join before releasing. |
| `BackgroundWorkRunner.requestCancel/cancel/shutdown` | Keep immediate operation fencing and durable logical Stop. Forward Stop to the ownership owner without freeing the physical slot on logical state changes or shutdown return. Retain join tasks even if the runner closes or loses UI references. |
| `BackgroundAgentSession.execute/invalidate` and host `Handle` broker | Preserve physical-idle waiting. Include connect, send, native/remote Stop, host broker/delegated tasks and final callbacks in the shared physical join. A provider terminal event alone does not join concurrent host commands. Keep fresh grants and `mayPerformOperation` checks. |
| `ConversationStore.startBuilder/stopBuilder/builderEnded/receiveBuilderEvent` | Use the same coordinator and conflict-root mapping as background work, before creating/starting physical execution. UI receipt, `finishedAt`, releasing a security scope, and Stop returns cannot release ownership. Keep security scope valid while joining. |
| `NativeBuilder.start/beginTrusted`, `NativeTrustedWorkspaces` admission, foreground room brokers | Route all top-level physical execution through that coordinator. A lower-level builder invoked inside an admitted background executor inherits the existing lease; a foreground build acquires its own from the SAME registry. No unadmitted trusted-builder side entrance. Join preparation, editing, checks, delegated commands and finalization. |
| Native process / transport / broker execution owner | Supply an explicit awaited physical-exit/join result. `NativeProcess.terminate()` is asynchronous; its caller must retain and await physical completion. Existing leader wait/group signalling does not establish arbitrary detached-descendant or remote-operation quiescence. Treat unprovable cases as uncertain. |
| Reopen / outcome reconciliation | List retained reservations before resume; block matching uncertain operations, with no PID/TTL reclaim. Expose host-only reviewed physical verification, preserve operation tombstones, and separately reconcile logical pending steps/results before any newly authorized operation. |

Handle `workspaceBusy`, `limitReached` and transient `registryBusy` as admission
deferrals; use a bounded host queue/backoff outside the component and reauthorize
before retry. There is no internal queue, fairness policy, priority or busy wait.
Malformed/missing state, unsafe file permissions/link type, configuration mismatch,
unsupported sync and I/O failures are fail-closed errors, not empty capacity.
An idle reserved worker conservatively consumes a slot; minimize delay to dispatch.

## Validation and acceptance still required

Focused component gate:

```sh
Scripts/test-physical-ownership.sh
```

Native core integration compilation and nearby regression gate:

```sh
swift Scripts/test.swift PhysicalWorkOwnershipTests BackgroundWorkRunnerTests BackgroundAgentSessionTests
swift Scripts/build.swift --verification
```

The focused suite races simultaneous same-process callers and self-execs independent child processes. Barriers hold admitted
work until the parent releases it, so the workspace race and capacity exhaustion
are checked while winners are still active. SIGKILL crash tests reopen the registry
in reserved/executing/Stop-requested states and verify continued workspace, capacity
and operation-ID exclusion. A separate fixture kills an owner while its physical
child survives, then verifies exclusion through the child's independent exit and
explicit recovery. Delayed physical completion ignores cancellation until
a separate continuation is explicitly released. No real provider or app library is
used. The full private build compiles this new source automatically by directory
enumeration; a successful build does not connect it to app admission.

Before claiming D2 fixed, integration owners must implement the caller changes and
run app-level tests with at least two foreground/background conversations and two
independent app/helper processes using one registry: canonical aliases, simultaneous
admission, shared exhaustion, Stop ACK before actual idle, broker/process completion
after logical teardown, crash with a surviving physical operation, reopen without
replay, uncertain remote Stop and explicit recovery. Verify every physical entry
point is covered and no cancellation/final-receipt path releases early. This
component's tests do not establish those app properties.

Remaining limitations: cooperative macOS local-filesystem scope; stable namespace
and shared-root configuration are caller obligations; physical-exit evidence is a
host attestation; no nested-root overlap detection, multi-root transactions, global
service across OS accounts, capacity migration, tombstone compaction, fairness or
power-loss/fault-injection hardware validation. Crashes can intentionally exhaust
capacity until reviewed recovery. None of those restrictions is relaxed by Stop.
