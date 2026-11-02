# Background checkpoint storage — private adapter candidate

This adds `BackgroundWorkStore` on top of the separate `BackgroundWorkEngine` candidate. It is not wired into the running app, does not choose a live-library location, and supplies no provider, broker, installation or account capability. The host must provide an existing, canonical, owner-only local directory outside every agent-writable workspace, plus the current Project and originating conversation UUIDs.

## What the adapter supplies

- One engine attachment per store instance. A nonblocking exclusive `flock` on a permanent lock-file inode excludes cooperating writers using the same directory. The engine's save closure retains the store and its lock, including while an old physical worker is winding down. There is deliberately no public unlock/close that could free a live engine's ledger.
- A versioned JSON envelope bound to the exact Project and conversation. The engine validates saved task, state and session invariants before it exposes a restored engine. Loading starts no work and does not restore permissions. A second factory call, wrong scope, unknown version, corrupt primary or missing primary with a recovery copy is refused, not converted to an empty ledger.
- A 2 MiB bound on the complete envelope, including metadata. This can be slightly stricter than the engine's snapshot-only bound; save failures fence execution rather than truncate history.
- Descriptor-relative file access, no-follow traversal of every supplied directory component, private permissions, regular-file and single-link checks, bounded reads, and checks that the directory and permanent lock names still identify the opened inodes. Ordinary external primary modifications are detected before replacement.
- Complete writes to a new owner-only temporary file, `fsync` and macOS `F_FULLFSYNC` before atomic replacement, then directory `fsync`. A prior-primary recovery copy is replaced and synchronized before the primary changes. No unsupported synchronization call is silently ignored. This relies on the local filesystem and hardware honoring those system calls; synthetic tests cannot establish physical power-loss behavior.
- Failure propagation to the engine's storage fence. A failure after primary replacement may have committed the new document: it is uncertain, not a promise that the old document was restored. Current in-process execution is fenced and unsaved success is not published. On reopen the visible primary is validated; pending operations still require exact-step reconciliation.

## Host lifecycle

Construct the store only from host-resolved storage and identity, then call `makeEngine(maxConcurrent:authorize:execute:)` once. The returned engine is the normal engine API. Current grants, workspace ownership/revision, resource checks and separate provider identities remain the host's responsibility. Neither a saved scope nor the file lock grants execution permission.

On shutdown, call the engine's `shutdown`, stop/reconcile the underlying operations, and keep the old engine alive until its workers physically finish. A new store cannot acquire the same lock while the old store is still retained. Opening a different copied directory is a different lock, not a supported concurrent replica; the host must prevent app copies from executing replicas of the same work.

The adapter uses the engine's existing synchronous `Save` contract and therefore synchronous bounded file I/O on the main actor. It must **not be presented as proof that disk stalls cannot delay chat**. Before live UI wiring, the engine/persistence execution context needs a serialized off-main or asynchronous persistence design, preserving save-before-execute and cancellation ordering. No semaphore-based main-thread waiting or silent downgrade of synchronization should be used to hide this limitation.

The private directory and its ancestors must remain host-owned and outside agent write grants. `flock` coordinates cooperating local app processes; it is not a defense against arbitrary malicious code running as the same macOS user. Metadata/byte checks detect normal replacement and conflicting edits, not an absolute guarantee against a hostile same-user race.

## Recovery evidence, not automatic rollback

`background-work.previous.json` is the previous committed primary, not a runnable fallback. An old copy may predate a cancellation, result acknowledgement or pending provider action. Never automatically execute, publish results from, or restore it over a missing/corrupt primary. Preserve both files and reconcile against host broker/transcript evidence first. Recovery envelope versions and scope are checked; a manual recovery must also pass the engine's full snapshot validation.

The permanent lock file is never unlinked during ordinary shutdown. Temporary leftovers from an interrupted process are never loaded as tasks.

## Crash-leftover maintenance

Every write goes to a fresh `background-work-<lowercase UUID>.tmp` file that is renamed into place on commit, so any file still carrying that name is an uncommitted write. Save-before-execute means no step ran on its contents: the committed primary (and, for a finished step, its still-pending step ID) remains the record, and reconciliation still needs independent broker evidence.

When a store or storage session claims its ledger, while holding the exclusive writer lock and before reading anything, it runs one bounded maintenance pass:

- It scans at most 1,024 directory entries. A larger directory is refused with `maintenanceRequired` before anything is removed or read; the host must inspect it.
- It removes only names that exactly match the temporary pattern **and** are private (no group/other bits), single-link regular files owned by this user, within the 2 MiB document bound, not the inode of the primary, recovery copy, archive or lock, and still the same inode at the moment of removal. The directory is then synchronized.
- Anything else with a matching name (a symlink, directory, FIFO, hard-linked, foreign-owned, non-private or oversized file) is left untouched and counted. Names outside the exact pattern are never considered.
- The result is reported as `BackgroundWorkStorageMaintenance` (`removedTemporaries`, `retainedEntries`) on the storage session and on the legacy facade.

A single write can leave at most two leftovers (its own temporary and the recovery-copy temporary), and the next open removes them, so leftovers stay bounded however often the process is killed. The checks are the same no-follow, descriptor-relative ones as the rest of the store; they detect ordinary interference, not a hostile process racing as the same user.

## Settled-item archive

`background-work.archive.json` holds settled, resolved items (completed and acknowledged, or cancelled with no uncertain pending step) moved out of the ledger by the awaited runner. A stopped job whose step is still uncertain is evidence, not history: it is never written to the archive, so retention can never drop it. An archive written by 9cea7e0 may still contain such an entry; on open the storage session moves it back into the ledger, writing the ledger first (a crash in between leaves it in both files, the ledger copy is authoritative and the next open finishes the move). If it does not fit, open refuses with `unresolvedEvidence` and changes nothing. It uses the same versioned Project/conversation envelope, descriptor-relative no-follow access, private permissions, synchronized temporary file and atomic replacement as the ledger, with no recovery copy because it is bounded history. Every entry is validated as settled and in scope; a corrupt or foreign archive is refused at open, never treated as empty. Retention is at most 256 entries within 2 MiB, oldest archive pass first. The legacy synchronous facade only reads and validates it.

## Review commands and limits

- `swift Scripts/test.swift BackgroundWorkStoreTests`
- `swift Scripts/test.swift --reuse-core BackgroundWorkDurabilityRegressionTests`
- `swift Scripts/test.swift --reuse-core BackgroundWorkTests`
- `swift Scripts/test.swift --reuse-core OpenFloorTests`
- `swift Scripts/build.swift`

The new suite exercises real file replacement and synchronization in synthetic temporary directories, two independently opened lock descriptors, engine-retained lock lifetime, saved result acknowledgements, uncertain-step restart and terminal cancellation, injected pre/post-replacement failures, invalid schema/scope/state preservation, unsafe links/special files, and external directory/lock/checkpoint replacement. All results must be read from the actual host command receipts. It also checks crash-leftover maintenance and its look-alike and over-large-directory refusals. BackgroundWorkDurabilityRegressionTests kills real child processes with SIGKILL at storage boundaries, then reopens. Nothing here launches another installed app, simulates a power cut, connect a provider, post a result into a real conversation, or verify UI latency.

Independent review, asynchronous persistence/UI wiring, provider-session and broker integration, correctly scoped transcript deduplication, isolated combined acceptance checks and a separately approved install plan remain required. Existing computer-control tasks and both stable/Staging libraries are untouched.
