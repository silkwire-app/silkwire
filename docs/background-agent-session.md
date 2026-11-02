# Background native-agent session boundary

## Status and scope

`BackgroundAgentSession` is an injectable executor adapter for `BackgroundWorkRunner`. It uses the app's real `NativeAgentTransport` interface, not a second provider API or a foreground `NativeRoom` seat. This candidate adds only this adapter, its synthetic tests and this document on top of runner candidate AE860710 at 596b283. It does **not** enable background jobs in the installed app, select a live ledger, connect real providers, move conversations or install anything. Independent review and the remaining app/host integration are required.

Construction has no effects. The runtime host must supply all three closures:

- `factory(agent, backgroundSessionKey)` creates a **fresh, unconnected, exclusively owned** native transport for the exact teammate and dedicated saved background session key. There is no default real-provider factory. A transport already reporting an identity is refused without closing or mutating that foreign transport. The host must not supply an object concurrently connecting elsewhere; a nil identity alone cannot prove a misconfigured factory's ownership.
- `prepare(context, hostReceipt)` assembles a bounded prompt and **current** capability snapshot for every exchange. Copied room text, old capabilities and model replies cannot grant access. The original task and verified checkpoint must survive follow-ups. Recheck grants and resource budgets here before each connection/submission; one runner step can contain several provider exchanges.
- `handle(untrustedReply, context)` interprets the reply and calls the **actual app broker** with host-owned roots, workspace identity, permissions and approval policy. Check `context.mayPerformOperation()` immediately before **every** operation and after awaits; pass the fence through to any deferred broker queue. Await the real physical outcome. Return a bounded host receipt as `.followUp`, or an explicitly host-validated `BackgroundWorkStep` as `.outcome`. A model claiming success, a terminal event, or text containing an `ok` field is not evidence that an operation succeeded. No reply parser or automatic WORK/READ/COMPUTER execution is provided by this adapter.

A host can pass `session.execute` to `BackgroundWorkRunner.open(...execute:)` after binding the adapter to that runner's item. The runner is still responsible for physically saving the pending step before executor entry, authorizing it, saving confirmed progress/results, preserving uncertain work for reconciliation, and delivering/acknowledging its durable outbox. An adapter outcome is not a new durable checkpoint until that runner's save succeeds.

## Session identity and event ordering

An adapter binds one exact item ID, Project/conversation/workspace/agent/revision scope, and dedicated background session ID. Execute must name the saved pending step and carry a current operation fence; invalid context schema is refused before constructing a transport. There is only one physical executor at a time per adapter.

Every exchange gets a fresh transport object and a fresh native request ID. Callback closures capture that particular response and active execution. A captured callback from a retired transport cannot become a callback for its successor. This is necessary because the shared native event enum does not attach a request ID to every delta or terminal event.

The first connect receives no saved provider identity. Later exchanges/steps may resume **only this adapter's own confirmed identity**, never a supplied foreground identity. The runtime host can additionally deny known foreground/other-job provider IDs through `forbiddenProviderIDs`. Returned and final identities must remain the same on resumption. The adapter cannot independently discover every other provider session; the host must supply this exclusion set and maintain job/session ownership.

A reply is not handed to the host until **both** its terminal `completed` event and its original `send` acknowledgement have arrived, in either order. An early terminal followed by a send error is a failure. Unexpected reply text/terminal events before dispatch, disconnects, recovery callbacks and non-completed terminals require host reconciliation; recovered text is never silently replayed as new success. Identity/activity events are not terminal results or authority.

Only after confirmed terminal + acknowledgement does the adapter retain a reusable identity. It preserves the provider session ID/model, marks the session started, and drops stale run/request/turn recovery tokens. Marking an already-used session unstarted can select a new Claude session or the wrong Codex resume path. On **any execution failure**, the adapter closes admission and discards reusable identity; a later call cannot automatically retry uncertain work.

## Stop, revocation and physical ownership

`invalidate()` synchronously closes admission and invalidates the context exposed to host callbacks. This is an **in-process fence**, not a durable job cancellation or evidence of provider Stop. The host must also call the runner's synchronous `requestCancel`, then await its durable `cancel` outcome and report storage failures honestly.

Runner cancellation propagates through the executor task. Cancellation during preparation or a host broker callback does not release the physical worker until that awaited closure returns. Cancellation during connect closes this adapter's own connector but still awaits the outstanding connect return. During an outstanding send/reply, it requests provider Stop, awaits the real Stop outcome, and also cannot bypass the original send acknowledgement. **Inspection of the existing Codex and Claude transports showed that `stop()` can return after requesting interruption, before the native provider's terminal event.** The adapter therefore additionally waits for a `completed` or `interrupted` terminal on the exact response, including callbacks arriving after cancellation. Such callbacks can release physical ownership but cannot publish text, revive execution or call the host reply handler. A held or non-cooperative provider continues to occupy the runner's slot/workspace even after both acknowledgements have returned.

A disconnect, failed terminal, interruption timeout or thrown Stop is not proof of physical idleness. Without a confirmed terminal the adapter exposes `needsProviderIdleConfirmation` and retains ownership until the runtime host independently verifies that the exact provider request/process is no longer active, then calls `confirmProviderIdleAfterHostReconciliation(itemID:stepID:)` for that exact item and pending step. Foreign/stale confirmations are refused. This is runtime host input only, never a model protocol or automatic timer fallback; it does **not** reconcile the durable job or claim the original operation succeeded. A failed Stop remains an unconfirmed error even after physical idleness is independently established. The app integration must implement this evidence/recovery path before enabling the adapter. Retiring the transport happens only after these boundaries; no semaphore, main-thread disk wait or detached fire-and-forget provider work is used.

A runtime without a new event cannot detect an externally flipped fence by itself until another await resumes. The owning host must actively cancel/invalidate when revoking or stopping; a captured Boolean check is not a notification mechanism. Physical timeouts/deadline handling belong to the provider/host and must never release ownership merely because a timer or Task cancellation fired.

## Bounds

- Runtime exchange budget: default 8, accepted range 1...32, per runner step. Exhaustion fails rather than resetting or silently submitting more work.
- Prepared prompt: nonblank, at most 24,000 UTF-16 units; prompt plus capability text at most 32,000. The actual native provider also applies its own limits.
- Host follow-up: nonempty and at most 24,000 UTF-16 units.
- Accumulated or replacement provider reply: at most 65,536 UTF-8 bytes; overflow fails, never silently truncates into a supposed verified result.
- Runtime callbacks remain responsible for host resource/cost reservations, output redaction and any operation-specific bounds. No spending authority, provider-plan exception or new filesystem access is created here.

## Verification and remaining integration

Run the repository's native synthetic harness:

```
swift Scripts/test.swift BackgroundAgentSessionTests
swift Scripts/test.swift --reuse-core BackgroundWorkRunnerTests
swift Scripts/test.swift --reuse-core BackgroundPersistenceResponsivenessTests
swift Scripts/test.swift --reuse-core BackgroundWorkStoreTests BackgroundWorkTests
swift Scripts/test.swift --reuse-core BackgroundRoomIdentityReviewTests BackgroundRoomIsolationReviewTests BackgroundChatReviewTests
swift Scripts/test.swift --reuse-core RoomTests OpenFloorTests OpenFloorStopTests
swift Scripts/build.swift --staging
```

The new suite injects all native transports and host callbacks, deliberately holds connection/send/Stop/host-handling boundaries, supplies stale callbacks and conflicting identities, and uses isolated private files for actual runner/store integration. It also uses a real `NativeRoom` with synthetic transports to exercise foreground chat alongside the held background executor. It never starts a provider runtime, reads sign-ins or opens a live library. Passing these tests proves the injected boundary, **not** provider interoperability, live broker authorization or rendered app behavior.

Before actual app integration:

1. Adapt the existing native broker to an explicit background owner and operation fence. The current `NativeRoom` private continuation methods check their room/turn generation; they do **not** accept this runner context. Do not just wrap a room and assume Stop protects queued broker operations.
2. Provide the fresh provider factory, safe prompt/capability assembly, scoped broker implementation, grant-revocation notifications and budget reservations. Use existing native safety boundaries; never forward raw capabilities from historical chat.
3. Define crash-safe provider identity/uncertain-request recovery. This adapter's identity is runtime-only, deliberately not decoded from saved model text or a foreground conversation. Recreating it after restart is **not** permission to replay an uncertain pending step. Reconcile using independent host/provider/workspace evidence first.
4. Add app job admission/Stop/status controls and durable result routing/acknowledgement without overwriting drafts, reading position or another request. Integrate the separately reviewed composer/panel candidates on their exact revisions and re-run combined regressions.
5. Obtain independent review and a separate installation decision before any update. No live provider or installed-app claim follows from this candidate's private build.
