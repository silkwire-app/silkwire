# Saved-session startup hang — 2026-10-22

## Reproduction and cause

The owner reported Preview beach-balling during startup: Eve and Claude became Ready while Codex remained Connecting, then all three disconnected. The initial post-incident sample missed the active stall. Sampling a normal restart during its first seconds captured the UI actor in `NativeCodexRPC.receive`, overwhelmingly in `Data.firstIndex(of:)`.

The newline reader appended each 16 KiB pipe chunk and searched the entire accumulated prefix again. Large saved-thread JSON responses therefore caused quadratic scanning on the UI actor. The shared 50-second connection watchdog subsequently closed healthy providers along with the lagging one. Fresh-session/large-transcript typing fixtures did not exercise a large *provider resume response*; those are distinct acceptance surfaces.

## Fix

- `NativeJSONLineFramer` scans only newly received bytes, preserves fragmented UTF-8/escaped newlines and enforces the existing 36 MiB per-frame bound.
- A serial background decoder frames and parses JSON, delivering messages in wire order to the UI actor. Existing RPC/turn/generation checks, unknown-tool rejection and private-diagnostics suppression remain unchanged. Process-exit delivery waits behind queued decoding.
- Initial connections have independent deadlines. Both those deadlines and the outer watchdog retire only unresolved seats, preserve healthy connections and allow targeted retry. Late callbacks cannot overwrite the replacement seat or emit duplicate readiness.
- No permission, credential, library schema, provider identity or replay policy change.

## Verification

Artifacts: `output/startup-diagnostics/` in the `fix/preview-startup` worktree. The owner-library recovery backup there is private and ignored by Git; it is not a test fixture.

- `swift Scripts/test.swift NativeJSONLinesTests ConnectionLifecycleTests StorageTests RoomTests`: fragmented Unicode/ordering/bounds/error redaction, decoder drain ordering, large-response UI heartbeat, isolated provider timeout/retry, persistence and room lifecycle checks passed.
- A 12 MiB frame delivered in 16 KiB chunks decoded in **0.038 s**, with a **0.006 s** worst UI heartbeat gap.
- The opt-in `SILKWIRE_CHECK_SAVED_SESSIONS=1 swift Scripts/test.swift NativeSavedConnectionTests` reads the active owner's saved identities and grants without creating a store or writing the library. All three actual identities reconnected in **0.976 s**; worst UI heartbeat gap **0.015 s**; owner library byte-identical. No model turn, history copy, sign-in change or message replay.
- `swift Tests/run-transports.swift` covers the real subprocess/RPC boundary, including **12 MiB synthetic responses for both resume and read**, exact saved-turn recovery, current policy, unknown-tool rejection and process shutdown.
- `swift Scripts/build.swift --preview` builds the normal optimized application; the side-by-side installer retains the previous package and hash-verifies all nine bundle files without changing the library.

The normal installed-bundle connection check uses an isolated synthetic library and externally issued bookmark. It is separate from the read-only actual saved-session diagnostic above. UI inspection through the selected Peekaboo Bridge was unavailable; no automation permissions or selected host were changed.

## Screenshot-turn disconnect — 2026-10-22

The later `Codex early event bound exceeded; outcome unconfirmed` error is a
different failure from the startup stall. Before `turn/start` is acknowledged,
the connector buffered every notification matching the thread and any turn ID.
Input item notifications can contain complete image data; repeated item
notifications therefore consume the 1 MiB early-event budget without delivering
any assistant output. Large terminal notifications can also include all items.
The reported multi-image turn was aborted; a subsequent text-only turn completed.

The connector now ignores methods it never consumes and retains only compact
thread/turn identity, assistant delta, permission-denial indication and terminal
status. It does not retain input image echoes or terminal item bodies. The same
1,024-event/1-MiB early buffer limits, output limit, exact acknowledged-turn
filtering, runtime-tool denial and no-replay rules remain in force.

`swift Tests/run-transports.swift` reproduces the old exact failure with two
750-KB input echoes before acknowledgment, 1,100 irrelevant notifications, and a
terminal event containing 1.5 MB of input items. The fixed connector completes
with only the expected assistant text. Separate consumed-delta byte/count
overflows must still disconnect with the unresolved request identity preserved.
These are synthetic wire fixtures, not live screenshot-picker acceptance.
