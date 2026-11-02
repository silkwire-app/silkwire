# Safe parallel work in the D2 ownership registry

Status: delivered on `feature/safe-parallel` (base `6ca2797`). Nothing installed, pushed
or merged. Real process-exit proof is NOT part of this change: it comes from outside
Codex's `BackgroundJobExitVerification.swift`. Until it lands, every finished workspace
stays held as "uncertain" (the conservative default), so places still fill up.

## Two kinds of admitted work

| Kind (`PhysicalWorkOwnership.Kind`) | Runs with others? | Conflict |
|---|---|---|
| `foregroundBuild`, `backgroundJob`: **private workspace work** | Yes, side by side up to `HostOwnershipStorage.capacity` (4) | Never two on the same or an overlapping workspace (`workspaceBusy`) |
| `exclusiveOperation`: **shared, machine-wide resources** | No | Admitted only when NOTHING else holds resources (reserved, executing or uncertain). While it is held (`exclusiveHeld`) or queued (`exclusivePending`), no new private work is admitted |

An exclusive request queues durably on its first call (`ExclusiveWaiter` in a v3
ledger). From then on, new private work is refused, so the request isn't starved by
new arrivals. Requests are served first in, first out. A queue entry never holds
physical work: it only orders admission. Its waiter refreshes it every 25 ms, and an
entry left unrefreshed for 15 s (its process died) is pruned. Pruning can only change
ordering. Exclusion always comes from the held records.

API:
- `HostExecutionCoordinator.admit(…, wait:)` handles private work. With `wait: false` it
  refuses at once with the registry's reason (a teammate's begin uses this, so it
  never waits inside a turn).
- `admitExclusive(operationID:requester:resource:mayOperate:)` handles exclusive work.
  Cancellation withdraws the queue entry.
- `admissionState()` and `privateAdmissionRefusal(_:)` produce plain refusal reasons.

## Which existing operations are which (from the code)

**Private workspace work** (independent). Each runs `NativeBuilder` in its own private
`repository/worktree` and `TMPDIR`. Its Seatbelt profile (`NativeBuilder.commandSandbox`)
denies network, AppleEvents, mach-lookup and writes outside its worktree and TMPDIR,
with module caches in TMPDIR. The source is only read: Builder git uses
`GIT_OPTIONAL_LOCKS=0`, with hooks, fsmonitor, maintenance and gc off. It clones with
`--local --no-hardlinks`, and the run fails if the source changes underneath it.
- A teammate's trusted private workspace (`NativeTrustedWorkspaces` begin, including site
  and bundle-import begins), together with its run/checkpoint/apply/integrate/preview/
  diagnostic steps. `diagnostic` only *reads* the Staging library into the workspace's TMPDIR.
- A Builder-form run (`NativeBuilder.start`).
- A background job (`HostBackgroundExecution` → `HostNativeBuilderJobs`), which builds a
  finished workspace's committed worktree in another private copy.
- A background agent session (`HostBackgroundAgentJobs`), whose effects go through the
  same trusted workspace engine beneath its admission.

**Exclusive (machine-wide)**
- **Staging install and recovery** (`StagingInstaller.install` / `.recover`). These replace
  `/Applications/Silkwire Staging.app`, retain and swap the Staging library (which holds
  every room's trusted storage, private worktrees and job stores), and can relaunch the
  app, which ends in-process work. Wired to `admitExclusive` on
  `claude-code/installer-exclusive`; see [staging-install-exclusive.md](staging-install-exclusive.md).

**Not registry work** (documented so nobody adds it by mistake)
- Computer control drives the real screen and keyboard. It's arbitrated by `DriveArbiter`,
  with the human first. Sandboxed builds can't reach the screen (no AppleEvents or
  mach-lookup), so builds don't conflict with it.
- Release / recovery (`reconcileAfterPhysicalExit`) acts on one exact record snapshot.
  It is not an admission.

## Workspace keys: what "the same workspace" means

A trusted begin that is not inherited is now keyed by its **own private run root**,
`storage/<agent>/<runID>`. That directory is created empty just before admission and
removed again if admission is refused. `NativeBuilder.beginTrusted(runID:)` uses it as the
run root, so receipts stay at `storage/<agent>/<id>/receipt.json`. The run's
`repository` and `worktree` lie beneath it and are registered as aliases of it. A
background job resolves the worktree back to that key. So:

- teammates working on the same granted source get different keys and run side by side;
- a job on a workspace waits for (or is refused by) that workspace's own record, whether
  open or uncertain. That's why hand-off still finishes the workspace first;
- the read-only source is no longer aliased to a workspace key. A host-written bundle-import
  root is still aliased, because it's that workspace's own effect;
- the site source (`storage/Site Sources/<name>`) is the room's one shared write. It's
  created on first use and serialized in process (`siteCreations`); afterwards it's only cloned;
- inherited work (beneath a parent admission) keeps the parent's key, unchanged.

**This deliberately replaces** the D2 contract rule "use the stable canonical granted source as
the conservative conflict root" for source-to-private-worktree builds
(`docs/d2-physical-work-ownership.md`). Under that rule every teammate in a Project
serializes, whatever the capacity. That's why raising capacity alone (6ca2797) didn't
separate independent work: a second begin in the same grant waited forever on
`workspaceBusy` inside the teammate's turn. Aliases are permanent and prefix-mapped, so a
legacy alias (for example a room's `storage` registered by an old site begin) can only
collapse keys onto a broader root. That costs parallelism, never safety.

## Exit and finish are tied to one admission

`HostBuilderOwnership.finish(builderRunID:)` hands its verifier a `HostExitSubject`:
- `operationID`: the registry record; for inherited work, the parent's;
- `kind` and `conversationID`;
- `executionRoot` and `conflictRoot`: the run root;
- `builderRunID`: the receipt or workspace ID;
- `inherited`.

The answer finishes only that admission's lease. `BackgroundJobExitVerification` keeps its
three members. `verifyForegroundExit` is now a `HostExitVerifier`, `(HostExitSubject) async ->
HostPhysicalExit`. `verifyExit(jobID)` and `verifyRecovery(record)` were already keyed to
one job or record. Process-exit proof is still outside Codex's work.

## Ledger versions and migration

- An idle older registry (for example capacity 1, v1/v2, no held records and no queue)
  migrates to capacity 4 and becomes **v3**. History and tombstones are kept.
- A busy one (anything reserved, executing or uncertain) is refused with
  `configurationMismatch` and left byte-for-byte untouched.
- A queued or held exclusive operation also writes v3. Older binaries accept only v1/v2,
  so they refuse a v3 ledger rather than misreading an exclusive record as ordinary work.
  That includes 6ca2797, whose capacity-4 code otherwise accepts the ledger.

## Hazards

- **Shared registry across builds.** `~/Library/Application Support/Silkwire Host Ownership` is
  app-global by design. Once this build migrates it, any older Silkwire build that uses the
  registry refuses it (capacity or version mismatch). That's fail-closed, but its work is blocked.
- **Installer waits for unproved work.** Installs now take `admitExclusive`
  ([staging-install-exclusive.md](staging-install-exclusive.md)). Work whose exit is not
  proved (for example an offline preview under practical release) stays uncertain, and the
  install waits until Jason releases it; the wait message says so.
- **Places still fill.** With the default verifier, each finished workspace or job keeps its
  place. After four, every begin is refused with the reason until Release (with real
  verification) frees one.
