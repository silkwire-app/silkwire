# Silkwire engineering roadmap (draft 2, consolidated)

Combines Claude's draft 1, Trace's "dependable autonomy architecture roadmap"
(codex-autonomy-architecture-roadmap.md, workspace 92C1F4C2) and Eve's questions.
November 1, 2026. A starting point for Astra/Fable review, not a promise.

---

## Part 1: for Jason (one page)

**Where we're going.** You describe a result. The team turns it into a visible
assignment, works within your boundaries, survives ordinary interruptions, and hands
you a tested build, without needing more messages to keep it alive. You can keep
talking, change priorities, pause or stop at any time. Later you can supervise the same
work from your iPhone or a browser.

**Why we keep hitting surprises.** Pieces of the machinery exist (task continuation,
background builds, file ownership, a saved queue for messages sent while we're busy),
but they're separate systems that were never proven to work together end to end.
Each surprise has been one of the gaps between them.

**The plan, in six stages:**

| Stage | Plain English | What you'll notice |
|---|---|---|
| R0 | **Prove the whole path once.** One request → saved assignment → private edits → checks → review → "ready to try", with no extra prompts. | We find the real gaps before building more. |
| R1 | **Assignments that stick.** Every request becomes a saved goal with an owner, finish line and status. | "Building" only appears when work truly started. Nothing silently dropped. |
| R2 | **Keeps going, recovers, obeys Stop.** Wakes the right teammate when anything finishes; survives restarts without doing work twice. | You can walk away. Stuck work says why. |
| R3 | **A team that converses.** Relay replies, calm status, stable chat. | Short, distinct replies; no jumping. |
| R4 | **Safe delivery.** Every build in its own folder; updates that close themselves, back up, and can roll back. | Updates just work; running app never touched. |
| R5 | **iPhone, web, more providers.** Built on the proven pieces above. | Check in from anywhere. |

R0 → R1 → R2 is the backbone. R3 small slices can continue alongside. R4's safety
rules apply the whole way. R5 waits until R1, R2 and R4 are solid.

**Every feature gets one of four honest labels:** proposed, built, tested, or in your
running app. Only the last one means you can use it.

**Decisions you've already made**
- Distribute from our own site first; later paid Mac and iPhone apps on the App Store.
- The existing VPS can host the small server the phone and web need.
- The Mac stays awake, on battery backup and a generator.

**Decisions still needed (before the relevant stage)**
- App Store edition: Apple's sandbox doesn't allow running agent tools or a shell, so the
  App Store version may need a lighter feature set or a different arrangement. (Before R5.)
- Apple Developer account for signing/notarizing downloads. (Before sharing builds.)
- Internet-outage behavior: wait and resume vs. pause and notify. (R2.)

---

## Part 2: engineering appendix

### What exists today, and what it doesn't prove (from Trace's source audit)

- **Continuation:** real machinery exists for registered computer tasks, with a finite
  budget; it needs computer control on, a connected teammate, an idle room and healthy
  storage. Not yet a general scheduler.
- **Messages while busy:** combined into a bounded saved queue and sent after the current
  turn; unsent additions return to the composer after restart. Useful buffering, not a
  goal queue. (This is the mechanism behind "prompt stacking"; each human message also
  resets task continuation budgets.)
- **Background builds:** results saved before acknowledgment, deduplicated; completion
  offers a follow-up turn. Tested with synthetic providers only.
- **Workspace ownership:** persisted claims/handoffs prevent conflicting edits; not a
  wake-up loop.
- **Safety:** permission checks, private source, receipts, honest interrupted states.
  Kept as foundations.

### Stage details and gates

**R0 Capability truth + walking skeleton.** One living capability map with the four
labels. One reproducible synthetic scenario from request to ready candidate, instrumented
so every stall has a reason. Reuse existing task/background systems first.
*Gate:* trace links request, goal, task, workspace, provider attempt, command, result and
candidate revision; a chat reply can never mark a goal complete.

**R1 Durable goals.** Host-owned goal record (intent, scope, acceptance criteria,
owner/subtasks, dependencies, status, next step, budget, evidence) above today's ledgers;
workspace claims, computer tasks and background jobs map onto it. Intake separates
new goal / amendment / question / stop.
*Gate:* "build this while I'm away" is admitted or explicitly declined before the reply ends.

**R2 Liveness, recovery, control.** Event-driven wake-ups (command exit, provider finish,
review, reconnect) plus a bounded watchdog instead of PASS loops. Budgets, backoff,
fairness, one lease per operation; reconcile on restart before any retry.
*Gate:* kill and reopen at each transition: no duplicate side effects, no lost task, no
auto-resend of an uncertain request; Pause/Stop works; blockers visible.

**R3 Conversation.** Later teammates receive the actual earlier answer before writing
(the relay); whole-card reveal, stable order (draft built: 027bc61), concise status
surface, no scroll jumps.
*Gate:* a unique fact from the first speaker shows up in later answers or they stay quiet;
order survives reopening.

**R4 Verified delivery and data safety.** Edit → checkpoint → real checks → exact-head
review → immutable candidate in its own folder → separately approved install with backup
and rollback. Updater closes its own window and confirms the running revision. Storage
migration proven separately (backup, ownership, newer-schema refusal, crash recovery,
realistic scale) before activation.
*Gate:* failed/truncated evidence can never show as Ready.
*Note:* installing to one fixed place (/Applications) also keeps Login Items working
across versions; test builds must stop overwriting the folder of a running app.

**R5 Companion, web, providers.** Versioned authenticated event protocol from the Mac;
pairing/revocation, replay, dedup, explicit remote approvals; phone supervises, it is not
a second worker. New provider adapters prove send/ack/drain/stop/recovery/usage with
fixtures first.

### Eve's acceptance test for every message (belongs in R1/R2)

Send → saved acknowledgment → visible queue → teammate receives it → answer or explicit
failure. Must hold when Jason sends several messages while we're busy, restarts the app,
or loses Internet. No silent disappearance, and retries never run the same work twice.
(Open bug: two of Jason's messages vanished on Nov 1; diagnose under this test.)

### Eve's permissions question (decide before R5)

Direct download and App Store delivery need an explicit permissions strategy; local
work that runs in the downloaded app may not survive App Store sandboxing and review.

### Risks and unknowns

- Providers change tools, sign-in or limits without notice (contain with adapters).
- Usage limits and cost of long multi-agent runs (budgets in R2).
- Mac offline or app not running = no work; say so honestly on the phone.
- Storage switch-over is still unreviewed for live data.

### Review packet for Astra / Fable

Give them: Part 1, this appendix, Trace's full audit document, real receipts and known
incidents. Ask one for the smallest incremental architecture and the other to attack it
(hidden dependencies, failure modes, needless rewrites). Ask for: one-page roadmap,
reuse/change/build decision per module, dependency order with decision gates, risk
register, small validation experiments; effort ranges only after experiments; no dates,
no "zero surprises".
