# Practical release for sandboxed private work

Jason approved sweeping sandboxed private executions after normal completion,
failure and Stop, then releasing their ownership only after successful cleanup
and two complete kernel-lineage scans with no survivors (the execution tag is an extra signal). This is a practical cleanup policy. It is not
whole-workload kernel exit proof. Command success, process cleanup and admission
release are independent outcomes; a failed/stopped command stays failed/stopped.
Receipts retain `executionStatus`, `stopRequested` and a separate `physicalCleanup`
policy/evidence record. A Stop accepted during cleanup or receipt persistence
cannot publish an overall passing execution. Failed/stopped execution status is
preserved even when ownership is held; `ownershipState: needs-review` and
`physicalExitUnconfirmed` describe that separate unresolved cleanup.

## Inputs and integration

- Common base: `6ca27979ea135c3476909ecc32440a54d988ded9`.
- Physical-exit candidate: `5c48a62f9a5a2b11c0452f693e04b4b8370b5926`.
- Safe-parallel candidate: `4104ca5afdebafe2107d4a06772904e382c1ffd7`.
- Combined starting merge: `5c50e4f599309814461f57c453916748963863f0`.

`HostExitSubject` is now a compatibility name for `HostExitRequest`. It retains
operation, kind, conversation, execution/conflict roots, Builder run and inherited
status, and adds the runtime evidence capability, optional job, and immutable
attempt generation/canonical workspace identity. No identity comes from agent JSON.
Private cleanup answers themselves carry identity and run/job binding. A finish
validates that answer against its request and registry attempt. Recovery checks
its exact retained record again in the final registry transaction.

Safe-parallel's per-run keys, overlap exclusion, immediate trusted-begin refusals,
exclusive FIFO queue/admission and conservative v3 migration remain in place.
Source grants are read-only inputs, not shared private-work conflict keys.

## Launch and cleanup

`NativeBuilder` uses the host sandbox launcher for fixed Git preparation/evidence
operations as well as build commands. Host site creation and bundle import do the
same. Their profiles restrict writes to host-selected private paths and deny
network, AppleEvents and mach lookup. Process inspection of other processes and
reading their environment through kern.procargs2 are denied to private commands,
so another private workspace cannot discover an execution tag through those APIs. Nested command brokers use the same witness.
Already-sandboxed nested Builders keep the outer kernel sandbox; macOS refuses
reapplying Seatbelt there. Their launches preserve the outer execution tag. Their
inner admissions remain held without independent delegated exit evidence; this
does not grant the private exception to unobserved inner work.

Unsandboxed work cannot opt in by inheriting an environment variable: the host
chooses the launch path. Exclusive admissions never create private manifests.

Before launch, the host persists a private manifest outside command-writable
roots (0700 registry, 0600 regular single-link file, O_NOFOLLOW, atomic rename and
fsync). It contains the exact admission identity, Builder run/job, random execution
tag, original host audit token, a kernel unique-ID/PID-version start watermark, and each directly tracked child audit token plus its stable kernel lineage identity. The start lineage is also in the write-once binding. A separate
write-once binding preserves the expected run, job, tag and original host identity;
recovery rejects a manifest with a mismatched or missing binding.
Children start suspended; their unique ID and PID version are committed before they resume. Missing or inconsistent lineage, including legacy tag-only manifests, keeps ownership held. Each private
launch gets `SILKWIRE_PRIVATE_EXECUTION`. Descendants inherit it, including helpers
that detach from the leader's process group. Environment contents and arguments
are never logged by the scanner.

On leader exit, if output pipes remain open, the native executor also sweeps
its private attempt before waiting further for those pipes: a detached helper can otherwise keep those pipes open
and prevent final cleanup from being reached. Readers use cancellable polling;
an unjoined drain deadline records failure and retains ownership, never success.
The attempt is not sealed at this per-command sweep because final Git evidence
may still need to run. Final finish joins callbacks, seals launches, reloads its
manifest and sweeps:

1. Run the shared `StagingInstallWorkload.pass` kernel scanner over all live
   processes, with the job's suspended children as roots. Follow parent unique
   IDs and original parent PID versions through descendants and launchd
   reparenting, including a later exec. This is the installer's scanner, not a
   second implementation. The app process is not a private job root, so other
   jobs in that app remain independent.
2. Include possible orphans created after the job's start watermark whose
   parent exited, using the installer's conservative attribution rule. An
   unrelated older live app may excuse an orphan only after stable kernel
   identities at both ends and unchanged responsibility are checked. The
   execution tag adds evidence; hidden Apple-platform environments do not
   excuse a process. Include every still-live directly tracked process too.
3. Signal only proven descendants or tagged/tracked processes, using exact
   kernel audit tokens validated against the discovered unique ID and current
   PID version. Ambiguous orphans retain ownership until they exit; uncertainty
   cannot authorize terminating another workload. Never signal a polled PID.
4. Repeat inspection until two complete scans contain no survivors. A bounded
   five-second cleanup deadline or unavailable lineage is failure, never
   successful cleanup evidence.

Process exit/exec can race the separate `KERN_PROCARGS2` size/read calls, before
`proc_pidinfo` reports a zombie. The follow-up reproduced a successful crash check
followed by reconcile failing with `EINVAL` in that window. `ESRCH`, `EINVAL` and
`EIO` from procargs inspection invalidate that scan and reset the consecutive-empty
count. Cleanup re-enumerates within the original five-second deadline. Persistent
unreadability retains ownership with the last incomplete-scan reason; other
inspection failures and failed signals still fail closed. Recovery still performs
one fresh verification per reconcile; the crash test does not retry reconcile.
The inspector's direct snapshot API also re-enumerates within a bounded deadline,
requiring two fresh empty scans after a transition; cleanup passes its original
deadline into that API. A direct helper-discovery call therefore has the same
race handling without retries in the test or a renewed cleanup budget.

The answer is `.privateCleanup`, with explicit practical-policy wording. Strict
`.verified` kernel certificates remain a different result. Registry finish and
recovery reject private answers for exclusive work or a different attempt.

Apple's implementation of audit-token signalling is in
[proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
and its PID-version validation in
[kern_sig.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c).

## Recovery and cases that remain held

Recovery reloads evidence on both check and reconcile and reruns cleanup. A sealed
manifest is not a cached claim that future scans are empty. An unsealed manifest
can be taken over only after its exact original host is no longer live. A reused
host PID cannot impersonate that audit-token identity. An original host still
alive, outstanding local join, changed registry snapshot, stale attempt/foreign
workspace/job, unsafe metadata, missing required evidence, denied inspection,
failed signal or surviving descendant, possible orphan or tagged helper retains ownership with a reason.

Offline workspace previews use this same practical policy. The fixed host renderer
blocks network, joins its inspection and tears down its view before returning;
the Builder's final sweep still covers job descendants, possible orphans, directly tracked and tagged processes. It
does not signal shared WebKit service processes or claim their whole-workload
kernel exit. The preview stays in the operation/Stop permission lane, and its
receipt records practical cleanup separately from the preview/command outcome.
No agent-supplied flag can opt another host extension into this policy.
The attempt must already have sandboxed private launch evidence. A preview cannot
mint eligibility or clear an earlier coverage failure; exclusive and unsandboxed
attempts still record the missing strict worker witness even after tracked joins.

Provider/remote work, delegated executors and other host extensions without worker
coverage durably disable the private exception before dispatch. If disabling
cannot be persisted, dispatch fails. Earlier strict evidence without a complete
sealed certificate remains held, including crash-lost kernel subscriptions.
No missing manifest is treated as private-cleanup success. The strict verifier
continues to reject forks and missing exact exit observations.

The shared scanner uses macOS kernel unique identities and original parent PID
versions, so Apple hiding `/bin/sh` and `/bin/sleep` environments, tag removal,
PID reuse and reparent-then-exec do not justify release. This remains a practical
observation, not a privileged containment domain: work delegated to existing
launchd/XPC/remote services requires separate coverage and stays outside this
policy. If lineage cannot be established, ownership stays held. The scanner's
kernel interfaces and snapshot limits are documented in
`staging-install-exclusive.md`.

## Shared installer integration

Private cleanup reuses `StagingInstallWorkload` for kernel enumeration, lineage,
orphans and tag inspection. Installer scopes retain their original defaults;
private scopes supply job roots and `SILKWIRE_PRIVATE_EXECUTION`. The installer
lane remains exclusive and cannot accept private cleanup evidence. This change
does not edit `StagingInstallLane.swift`, `StagingInstallView.swift` or
`StagingInstallExclusiveTests.swift`. Nothing is installed, deployed, pushed or
merged into a shared branch.

## Verification

Run only synthetic fixtures and isolated ownership registries. Do not enable
live-provider tests. `Scripts/test.swift` accepts
`SILKWIRE_TEST_DEADLINE_SECONDS` (default 480) per test executable; expiration
records a nonzero exit and an explicit deadline message.

`PracticalReleaseTests` uses real processes and the production adapter for six
sequential Builders (including failure), three concurrent workspaces, Stop A
without disturbing B, detached helpers, stale job/workspace/attempt rejection,
restart cleanup and exclusive protection. Its explicitly labelled failed-signal
and failed-inspection checks inject just those failing syscall seams, with a real
helper present. They are not substituted for successful real-process acceptance.
`HostPhysicalExitTests` exercises the unchanged strict path with real processes.
`SafeParallelOwnershipTests` includes stub exit answers for ownership semantics;
it is not real cleanup proof. See the handoff receipt and raw logs for actual
results, including failures and reproduced baseline comparisons.

The real-process platform regressions leave a tagged `/bin/sh` child alive after
its job returns, and an untagged grandchild that execs `/bin/sh` only after its
parent exits and launchd adopts it. Both are found with their environments hidden.
With signals deliberately inert, cleanup fails closed and durable ownership stays
held; after each shell exits naturally, fresh production recovery releases it.
Missing lineage/root evidence also stays held with a real survivor present.

After a platform survivor exits, its regression waits up to 20 seconds for fresh
recovery proof under concurrent process load. Every retained verdict is logged
and must leave the registry held; only a newly verified reconciliation may pass.
This does not add retries to the existing crash-recovery regression or alter the
production cleanup deadline.

While private workers run, the host also uses the shared scanner every 50 ms to
persist positive descendant identities. A known worker's unique ID then remains
usable after its intermediate parent exits and it execs, even when macOS hides
its tag. Sampling stops when no known worker remains, restarts on the next
suspended launch, and is joined before sealing. Unknown orphans are not promoted
to known roots without positive lineage or a matching tag. Missed observations
remain conservative holds; incomplete sampling never substitutes for final full
scans. A real barrier-controlled regression proves durable observation before
parent exit, then production signalling and release after reparenting and exec.
Hold reasons retain the names, stable unique IDs and signal eligibility of the
last survivors, including audit-token lookup failures.
