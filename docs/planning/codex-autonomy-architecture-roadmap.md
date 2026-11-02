# Silkwire: dependable autonomy architecture roadmap

Status: Codex review draft, 2026-11-01. Planning and evidence audit only; not implementation approval or a claim that the end state exists.

## One-page direction for Jason

You describe a result, the team turns it into a visible assignment, works within your granted boundaries, survives ordinary interruptions, and returns a tested candidate without requiring more messages to keep it alive. You can keep talking, change priorities, pause, or stop. The phone eventually lets you supervise the same work; it does not create a second competing worker.

Native macOS remains a reasonable home for local files, processes and UI. That choice does not itself supply durable scheduling, reliable provider delivery, recovery, or safe installation. These are different engineering contracts, not successive requests for unlimited access. A browser client could eventually use a native host; it would not remove those contracts either.

The next architectural deliverable should be one living capability/dependency map, with each promise labelled **proposed / implemented / tested / available in your running build**. A source file or passing component test is not proof of the last two states. No responsible roadmap promises zero surprises; it should expose known gaps, uncertainty, dependencies and the experiment that resolves each uncertainty before larger investment.

## Audit boundary and revision

Private workspace 92C1F4C2-6EE2-444E-A7C3-A1BEEB857734; host-returned base `6a56b812b5f1dcc4ca0fad811fecc19c99d7070c`, copied from All Projects / silkwire-worktrees/claude-testbuild-1. This differs from the connection's running-build snapshot `c8f45ec498a865fda5da575d82e106716612c8f8`. Findings below apply to inspected source, not automatically to the running app or every historical build. Only this new document is changed. No accounts, live data, real provider requests, installation or deployment are part of this audit.

## What exists, and what it does not establish

| Layer | Evidence inspected in this source | Boundary / remaining proof |
| --- | --- | --- |
| Native host and provider boundary | `docs/architecture.md`; `NativeRoom.swift:600-635` | Swift owns coordination; provider calls are still discrete operations. Native code does not eliminate provider protocols, authentication, OS approvals, quota or outages. |
| Workspace ownership | `WorkspaceTasks.swift:1-85` | A persisted path-claim/handoff ledger prevents competing edits. This ledger is not the computer-task continuation registry and does not itself demonstrate a wake-up loop. |
| Durable agent continuation | `ConversationStore.swift:1192-1206`; `ComputerControlCenter.swift:41-56,443-483` | Real continuation machinery already exists for registered running computer tasks. It requires computer control enabled, a connected participant, an idle/non-archived room and healthy storage. It has a finite continuation budget and blocks on save failure. It is inaccurate to say there is no scheduler at all. |
| Continuation triggers | `ConversationStore.swift:1285-1304`; reconnect call located at line 1501 | After a settled turn, queued human input takes precedence, then job follow-ups, then successful-turn task continuation, then bounded Pass. Completion of an ordinary reply is not registration of a durable assignment. Exact liveness across failed turns, inactive rooms, sleep and provider outages needs broader acceptance. |
| Background command work | `BackgroundJobDesk.swift:203-241`; `BackgroundJobEndToEndTests.swift:1-90` | Result insertion is saved before acknowledgement, with result identity deduplication. Completion offers a follow-up model turn. A follow-up to explain a command result is not automatically an overarching build plan with a verified finish line. Existing end-to-end fixture uses synthetic providers and a stub executor; it is not live-provider proof. |
| More messages while busy | `ConversationStore.swift:1014-1030,1215-1233,1257-1300` | Additional drafts are combined in a bounded saved queue, delivered after the current turn. Saved unsent additions return to the composer after restart rather than silently sending. This is useful input buffering, not a durable dependency queue of independently tracked goals. |
| Safety and delivery | `docs/architecture.md` release invariants and build isolation contracts | Permission checks, private source, receipts and honest interrupted states are foundations to retain. They do not alone prove an exact tested candidate can safely replace the running Staging app and roll back. |

Some inspection output was display-shortened; narrower relevant passages were reread. An exploratory search for nonexistent `ComputerHost.swift` exited 2; it was corrected by locating `ComputerControlCenter.swift`. That search failure is not a failed product test. Command/test outcomes belong to the host receipt, not to this table.

### Prompt stacking: useful, but not the engine

There is a concrete mechanism matching Jason's observation: `send()` queues additional input while busy; `afterTurn()` dispatches it before task continuation. More messages can therefore create more model calls and extend a productive conversation. Also, `noteJasonMessage()` resets registered tasks' continuation counts. Either could contribute to the earlier experience. This audit does not establish which caused a particular historical run.

Calling it prompt stacking is a useful product description, but more prompts must not be required fuel. Combining messages also loses separate task identities and priorities. A future intake layer should distinguish **new goal / amendment / question / stop**, link each input to a goal, preserve provenance, and avoid treating casual conversation or an attachment's text as authorization.

## Proposed dependency roadmap

These are work packages for review, not permission to start every feature. Each package needs a named owner when scheduled, an exact candidate revision and evidence before its status advances.

### R0 — Capability truth and executable walking skeleton (next)

Deliver one short architecture map and a reproducible synthetic scenario: a normal human request becomes a saved assignment, agents edit a fixture privately, a background check returns, independent review runs, and one candidate is reported ready. No extra human prompt is allowed to propel the scenario. Instrument transitions and stalled reasons. First reuse/test the existing task and background systems; do not rewrite them on assumption.

Gate: the trace identifies request, goal, task, workspace, provider attempt, command operation, result and candidate revision. Closing a model reply cannot silently mark the goal complete. If initiation or continuation fails, Jason sees not-started/waiting/blocked rather than a reassuring promise.

### R1 — Durable goal intake and shared lifecycle

Add or adapt a host-owned goal record above the current specialized ledgers: intent, authorized scope, acceptance criteria, owner/subtasks, dependencies, revision, status, next step, bounded resource budget and evidence links. Map workspace claims, computer tasks and background jobs to it rather than creating unrelated competing schedulers. Persist admission before reporting accepted. Distinguish finished tests, finished subtask, reviewed source, packaged app and ready-to-try goal.

Gate: a synthetic "please build this while I am away" request is admitted or explicitly declined before the response ends; no task is stranded merely because its agent replied conversationally. Task records convey scope; they do not grant new access.

### R2 — Liveness, recovery and control

Use event-driven scheduling after command exit, provider finish, review/handoff and reconnect; add a bounded watchdog to reconcile stalled states, not a stream of empty PASS messages. Keep per-room fairness, capacity, retry/backoff, elapsed-time/token/step budgets and a reason for waiting. Persist the next eligible step and enforce one current lease/generation per operation. On restart reconcile physical work and uncertain provider delivery before considering retry. App termination/sleep is not execution; state clearly whether work needs the Mac awake/app running. An independent resident service is a separate decision only if that requirement cannot meet the product goal.

Gate: kill/reopen at admission, dispatch, command exit and result-save boundaries. No duplicate side effects, no lost task, no auto-resend of an uncertain user request. Pause/Stop prevents future dispatch and handles already-running processes honestly. Disconnected/disabled providers and exhausted budgets are visible blockers, not infinite loops. Prefer at-least-once events plus deduplication/reconciliation over an unprovable global exactly-once promise.

### R3 — Team coordination and usable conversation

Build on shared path claims and reviewed exact-head artifacts. Represent dependencies and handoffs explicitly; parallelize independent work, serialize conflicting edits and dependent publication. Give later conversational contributors the actual preceding answer before they generate their contribution. Preserve context provenance and bounds so missing history is visible. Buffering a card alone does not supply predecessor context.

Gate: synthetic teammates receive a unique fact introduced by the predecessor; later answers add value or remain quiet. Finish/read order is stable and survives reopening. While work proceeds, Jason sees a concise milestone/status surface with details optional, and can keep reading without scroll jumps. This is distinct from broad autonomy scheduling and can be verified as a small separate chat slice.

### R4 — Verified delivery and data safety

Retain isolated edits, exact committed-head checks, independent review, source preservation and signed/versioned output. Candidate builds use unique immutable artifact paths, not an app folder currently in use. The updater must verify complete workload exit, close its own blocking UI, preserve backup/recovery state and identify the installed/running revision. Resolve the reported Staging quit failure with a synthetic/native end-to-end install rehearsal before another real install. Do not fold storage activation into chat or scheduler changes.

Gate: edit -> checkpoint -> real checks -> exact-head review -> immutable candidate -> separately authorized install/recovery. Failed/truncated/unconfirmed evidence cannot become a green Ready status. Storage migration separately proves backup, exact content/media ownership, newer-schema refusal, crash recovery and realistic-scale responsiveness before activation. A passed storage foundation is not a passed live migration.

### R5 — iOS companion, web and broader providers (after host contracts stabilize)

Expose a versioned authenticated command/event protocol from the proven host, with device pairing/revocation, reconnect replay, deduplication, conflict policy and explicit remote approvals. The phone is initially a supervisor, not another process controller. No automatic transfer of Staging conversations, credentials or permissions. A remote always-on worker/server is a separate deployment/security decision, not something a native UI or model upgrade provides for free.

Gate: disconnected companion catches up without restarting work, duplicates cannot re-execute commands, revocation takes effect, and the phone reports Mac-asleep/offline honestly. New provider adapters prove send/ack/drain/terminal/Stop/recovery/context/usage contracts using fixtures before opt-in integration testing.

Dependency outline: R0 -> R1 -> R2 is the unattended-work spine. R3 can progress in bounded parallel slices, but depends on R1/R2 for durable work coordination. R4 delivery/storage safeguards remain gates throughout, not deferred polish. R5 consumes the stable R1/R2/R4 contracts. Broad feature ideas enter a backlog with dependencies; they do not interrupt the current checkpoint by default.

## Independent architecture review packet

Jason suggested using Astra and/or Fable for a larger-picture review. This document is a model-independent packet for that review; no alternate model was invoked and no settings were changed in this task. Provide reviewers the same end-state brief, exact source revision, this capability inventory, real receipts and known incidents. Ask one reviewer for the smallest incremental architecture and another to challenge failures, hidden dependencies and unnecessary rewrites; compare disagreements rather than concatenate essays. A stronger model can improve analysis, but it cannot substitute for source evidence, acceptance tests or a host that actually schedules work.

Required output: a one-page human roadmap plus engineering appendix; reuse/change/build decisions by module; dependency order and named decision gates; a risk/unknown register; small validation experiments; scope and confidence-based effort ranges only after experiments. Do not promise dates or zero unknowns. Do not mislabel a proposed model or uninspected build as verified.

## First acceptance matrix to implement or extend

- Intake: one prompt, no follow-up; clear outcome whether the goal is admitted, ambiguous or outside scope.
- Propulsion: final chat reply, background return, failed turn, disconnected provider, capacity exhaustion and inactive conversation all produce explicit next/wait/blocked states.
- Recovery: app restart and host crash around each persisted transition; prevent duplicated dispatch and reconcile uncertain actions without replay.
- Ownership: two agents, overlapping source, explicit handoff and independent review of the exact tested head.
- Human control: amend a goal while busy, ask an unrelated question, Pause/Stop and separate installation approval; none widens original authority implicitly.
- Reading UX: no empty viewport after Send; no new card inserted above already-published text; concise status; completed/recovered content remains available.
- Scale: long histories and media, multiple Projects, slow disk/provider and bounded queues without blocking typing or losing provenance.

Existing relevant suites to reuse include `ComputerRoomTests`, `BackgroundJobEndToEndTests`, `BackgroundWorkDurabilityRegressionTests`, and `BrokerTaskIsolationTests`. Their presence is not proof that the combined goal-to-candidate workflow passes. This planning-only task will record any executed suites separately in its host receipt; no production runtime capability is added by this document.
