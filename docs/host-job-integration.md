# Host background-job integration (contract v1)

This feature connects the durable runner to D2 ownership and supplies actual native
Builder/provider-session executors. It does **not** establish app/UI work/chat
separation. Room scheduling, application router injection, job cards, result
presentation and the app demonstration belong to the parallel room lane. Exact
insertion patches are included in the handoff, outside this feature commit.

## Concrete host API

`HostBackgroundJobService.open(storage:execution:authorize:execute:) async throws`
uses the existing asynchronous BackgroundWorkStorageSession and BackgroundWorkRunner.

- `submit(HostJobRequest) async throws -> UUID` accepts stable `operationID`, a
  host-validated scope (Project/conversation/workspace/provider/source revision), a
  work description of 1–240 UTF-8 bytes and existing bounded step limits. It awaits
  durable identity claim and enqueue, then returns the same job ID while a
  host-owned Task executes independently. A partial acceptance fails closed: its
  identity cannot be silently submitted as fresh work.
- `snapshot(UUID) -> HostJobSnapshot?` exposes queued/running/stopping/completed/
  failed/needsReview, a persisted monotonic UInt64 revision, progress separately
  from completion/result identity, pending step and acknowledgement state.
- `events() -> AsyncStream<HostJobSnapshot>` buffers the newest 64 events per
  observer; gaps require refreshing a snapshot. Ending observation never cancels
  execution. Repeated snapshots at the same revision are permitted.
- `requestStop(UUID)` fences immediately. `stop(UUID) async throws` reports durable
  logical Stop and D2 Stop persistence errors; acknowledgement is not physical
  exit. A known terminal job is idempotent. A missing ID is not an accepted Stop.
- `pendingResults` and `acknowledgeResult(_:resultID:)` expose the existing runner
  result seam. The room/result lane durably inserts and deduplicates by resultID
  **before** acknowledging. There is no second delivery mechanism.
- `shutdown() async throws` fences and records logical shutdown without waiting for
  blocked physical work. `joinLocalExecutors()` explicitly waits for retained local
  worker callbacks; it does not prove descendants/remote exit or recover D2 records.

There are at most 64 accepted queued/running jobs per service, 64 concurrent
acceptance/mutation waiters and 64 admission waiters per coordinator. The existing
bounded runner/archive and the registry's 4 MiB/10,000-entry bounds still fail
closed. Identity tombstones survive bounded result archive retention. History
exhaustion requires reviewed maintenance; no compaction is introduced.

## Physical ownership and real callers

`HostExecutionCoordinator.application` selects one host-owned path independent of
library, profile, conversation and workspace:
`~/Library/Application Support/Silkwire Host Ownership`. Initialization and every
D2 transaction run on HostOwnershipStorage, away from MainActor. Existing directory
permissions are validated, never repaired. Tests inject private directories; no
live path is opened merely by loading these types. Every cooperating helper must
use that same registry and capacity **1**. An incompatible persisted capacity fails.

The D2 ledger now also durably records host-authorized source/private-root aliases
and submit identity fingerprints under its existing cross-process lock and
fsync/atomic-replace boundary. There is no separate alias registry per room or
process. Canonical directory identity and conservative path fences are preserved.
Host mappings are immutable; an agent path or receipt is never accepted as a grant.

`HostBackgroundExecution` wraps the actual runner Execute callback: pending step
identity is durable first; authorization is checked again around admission and
before dispatch; beginExecution commits before any effect. Its TaskLocal admission
is inherited by sequential native build/test steps. Stop fences the scoped broker
callback immediately. After execution returns or throws, a cancellation-independent
host join runs before D2 release or any terminal result save.

`HostNativeBuilderJobs` invokes the real NativeBuilder preparation/edit/build/test/
finalization path beneath that admission. `HostBackgroundAgentJobs` invokes a
dedicated BackgroundAgentSession with fresh transports, separate provider identities
and the actual host Prepare/Handle broker closures. No chat session or room observer
owns either executor.

Foreground `NativeBuilder.start/beginTrusted` now admit through the same coordinator.
NativeTrustedWorkspaces admits before site creation or bundle restoration, transfers
that physical owner into its Builder, and retains it until finalization. All
commands, delegated brokers, offline preview and diagnostics participate in the
same lifetime. NativeCommandBroker propagates the admitted runtime capability to
child brokers and rechecks its fence at dispatch. Builder receipt writes run on a
serial actor with monotonic write revisions, preventing stale async overwrite.

## Evidence and conservative limitations

`HostPhysicalExit.verified(evidence:)` is trusted independent host evidence of the
**entire executor**, not successful command output, a leader exit, pipes draining,
Stop ACK, PID absence, elapsed time or provider text. Unknown evidence records
`.uncertain`, retains the sole physical slot and reports needsReview. Every release
also respects known outstanding sequential children and Stop tasks. NativeBuilder
retains its own security-scope references independently of UI teardown.

The current native process launcher cannot prove the absence of arbitrary detached
descendants or remote provider work. Consequently the default real Builder verifier
is **unconfirmed**, and its first real execution conservatively retains ownership
pending independent review. Do not replace this with a verifier that merely returns
success. The recovery lane can use exact-record
`HostExecutionCoordinator.reconcileAfterPhysicalExit(_:evidence:)`; that operation
never resumes/replays a logical pending step or supplies a result.

Same-process sequential nested Builders inherit admission. Delegated helper commands
remain under the parent's host broker and slot. A sandboxed helper that constructs a
new top-level NativeBuilder currently cannot authenticate/inherit the parent admission
across the process boundary and fails closed when it cannot access the global
registry. That helper-Builder bridge remains missing; an environment endpoint is
never sufficient authority to bypass admission.

Legacy synchronous BackgroundWorkEngine/BackgroundWorkStore and an unbound runner
`open` overload remain for compatibility/testing; production background integration
must use the service, which requires ownership. They remain explicit potential
bypasses if a future production caller selects them. Raw NativeProcess APIs remain
available for chat transports and read-only host inspection, outside this build-job
policy. No app-wide enforcement against arbitrary same-UID code is claimed.

## Verification

```
Scripts/test-physical-ownership.sh
Scripts/test-host-job-integration.sh
swift Scripts/test.swift PhysicalWorkOwnershipTests BackgroundWorkRunnerTests BackgroundAgentSessionTests BackgroundWorkCapacityRegressionTests BackgroundWorkDurabilityRegressionTests HostJobIntegrationTests HostNativeBuilderIntegrationTests
swift Scripts/build.swift --verification
```

The host tests deliberately block synthetic executors and child joins while submit,
independent chat/control callbacks, Stop, teardown and another conversation run.
Independent helper processes contend on the same host coordinator. Reopen never
schedules uncertain work. The native adapter test runs real isolated Git preparation,
Seatbelt build/test commands and broker cleanup while retaining unknown descendant
ownership. These are synthetic responsiveness and private native execution tests,
**not a real integrated app/UI chat/delegation demonstration**. Exact commands,
exit codes, complete logs and baseline comparisons are in the handoff.

## Room protocol, injection and verification-only Release

The room adapter codes against `@MainActor protocol BackgroundJobHost`, declared in
`BackgroundJobHost.swift`. `BackgroundJobHostInjection.swift` owns the process-lifetime
injection map and concrete `openNativeBuilderHost`/`openAgentHost` factories. Both use
its one coordinator. Registration rejects a concrete host configured with another
coordinator. At library bootstrap, open/register the host for each authorized
conversation; pass `injection.router(scope: freshHostScopeResolver)` to the two
NativeRoom constructor sites in ConversationStore (the current source lines 786 and
935) through the separately supplied room insertion patch. The fresh scope resolver
must use current host grants and the originating room ID, never agent-supplied
Project/conversation/path/revision fields. Foreground Builder receives the same
coordinator. No room scheduling or view file is changed by this feature.

The protocol exposes `heldPhysicalOperations()`,
`checkPhysicalExit(operationID:)` and `reconcilePhysicalExit(check)`. A check returns
an opaque, unencoded runtime ticket and a reason/verdict. Reconciliation validates
the ticket issuer/identity, compares the exact retained record, refuses a pending
local join and **calls the independent verifier again**. No force flag, evidence
string or agent-facing Release operation exists. A failed/unknown verification
returns `retained` with a clear reason. A successful release changes only D2's
physical reservation; it preserves the unresolved pending step, job identity and
outcome, never replaying work or producing a result. The default verifier is
unconfirmed. Claude Code's evidence implementation plugs into `verifyRecovery:`.

The host integration suite now kills an actual service owner while its controlled
worker survives. A kernel NOTE_EXIT subscription is registered against that exact
worker before the crash. The fixture's complete execution scope is known to contain
that one child and no descendants/remote work. Release is refused while it survives;
only the child completion protocol plus observed exact-process exit and reaped
owner SIGKILL permit verified reconciliation. Ordinary synthetic chat/status/Stop
remain responsive. This fixture does not supply a general production process-tree
or remote-executor verifier.

Host aliases and submit fingerprints upgrade the ownership ledger to format 2.
Generic D2 format-1 ledgers remain readable; old D2 binaries refuse format 2 instead
of silently dropping host metadata. Every participating app/helper must ship this
updated registry reader/writer. No live registry migration is performed here.
