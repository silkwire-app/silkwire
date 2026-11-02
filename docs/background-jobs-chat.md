# Background jobs: the chat side (room lane)

When a teammate asks for long work (a `WORK_PROJECT` `run` step: builds, tests,
any workspace command), the room hands it to the **BackgroundJobHost** (contract v1,
`Sources/Silkwire/BackgroundJobHost.swift`, unchanged from the host lane). The
teammate's turn ends with a one-line note as soon as the host durably accepts the
job (or refuses it). Jason and the other teammates keep talking and delegating
while it runs. A job card shows who, what, state, elapsed time, Stop, and Release
when the host says the work may still be running. A completed job's result is
posted to the room exactly once.

The room runs, stops, releases and owns nothing itself. See
`docs/host-job-integration.md` for the host side.

## Switched on

`SilkwireApp` creates its store with
`ConversationStore(backgroundJobs: BackgroundJobBootstrap.application?.wiring)`. The
synthetic verification build passes nil, so its acceptance runs never touch the
application registry.

`BackgroundJobBootstrap`:

- **Hosts.** Opens one host per conversation that uses jobs, at library bootstrap and
  then on demand. A conversation uses jobs if its Project trusts Staging work on a
  Builder folder, or it has saved cards. Each host is opened once per process through
  `BackgroundJobHostInjection.application.openNativeBuilderHost`.
- **Storage.** Each conversation's ledger (`BackgroundWorkStorageSession`) is at
  `<Staging library>/Background Jobs/<staging|working>/<conversation>/ledger`, with
  Builder runs beside it. It is never inside Team Workspaces or a source folder.
- **Callbacks.** `BackgroundJobCommandBridge` supplies authorize, resolve, plan and
  the scope resolver. `BackgroundJobExitVerification` supplies exit and recovery
  evidence.

The store passes the same router (`wiring.router`, from the same scope resolver) to
both NativeRoom initializers (room-host-insertion.patch, applied unchanged). It gives
the room the same D2 coordinator and trusted-workspace exit verifier as the hosts.

### Command bridge (HostNativeBuilderJobs.Plan)

`HostJobRequest` carries no commands, so the Plan reads the job card's exact
WORK_PROJECT JSON through `BackgroundJobDesk.requestedWork` / `requestedJob` and
validates it on every call. That JSON is untrusted:

- **Commands.** It must be `run` with one `command`, or with checks named `build`
  and/or `test` (at most two). These are HostNativeBuildPlan's two slots. Each
  command is 1–4,000 characters with no credentials. Any other field is refused.
- **Source.** The requesting teammate's own private workspace in this conversation,
  found from the host's saved `receipt.json`, never from the JSON. Its retained
  worktree must be a clean Git top level at exactly the authorized revision
  (`scope.sourceRevision`).
- **Refusals.** Each has a plain reason, shown on the card. The host itself records
  only "needs review".

### Work places (see `docs/safe-parallel-ownership.md`)

The D2 registry has 4 places. Each private workspace has its own key (its run root),
so teammates' workspaces and jobs run side by side, never two on one workspace. An
exclusive host operation (such as a Staging install, not yet wired) waits for all of
them and blocks new ones. An open private workspace holds its place from `begin` to `finish`. So:

- **Run with an open workspace.** The job builds that workspace, so handing off finishes it (its receipt is
  the teammate's result so far). The job then builds the workspace's exact committed
  revision in its own isolated Builder copy. A run with uncommitted changes is refused:
  checkpoint first.
- **Run without an open workspace.** The run builds the teammate's most recently
  finished workspace in this conversation.
- **Begin when it can't be admitted.** If every place is taken (including by work whose
  exit isn't proved), or an exclusive operation runs or is queued, `begin` is refused at
  once with the reason. It never waits inside the turn.
- **Queued cards.** They say what they're waiting for.

### Exit and recovery evidence: one adapter file

`Sources/Silkwire/BackgroundJobExitVerification.swift` is the only source of exit
evidence. It provides `verifyExit` (background Builder job), `verifyRecovery`
(Release and recovery) and `verifyForegroundExit` (trusted workspace finish).

`verifyForegroundExit` receives a `HostExitSubject` naming exactly which admission and
Builder run it answers for. Its answer finishes only that record.

The conservative default answers "unconfirmed" with a plain reason: that work's place
stays held, the card shows why, and Release comes back "retained". Outside Codex's real
verifiers replace this one file. Until then, each job or finished trusted workspace keeps
its place held. After four, begins are refused. Release can't free a place, by design.

## What the room does with the contract

- **Submit.** The room chooses `operationID` (the job ID), saves the card to disk
  first ("Handing off…"), resolves the scope, then awaits `submit`. The
  `workDescription` is the card's plain-English title (240 UTF-8 bytes or fewer),
  with limits of 1 step. A refusal reaches the teammate as "No operation ran…". A
  reused identity (`reconciliationRequired`) shows "Needs review".
- **Requested work.** The host's Plan or Prepare callback can read the teammate's
  exact `WORK_PROJECT` JSON with `BackgroundJobDesk.requestedWork(job:conversationID:)`.
  It is quoted request data, never a grant; the host must validate it.
- **Status.** One `events()` subscription per host. Each event is refreshed with
  `snapshot(jobID)` (events may repeat or drop), and only a revision at least as
  new as the card's is applied.
- **Stop.** `requestStop` fences immediately. `stop()` is awaited separately and
  recorded on the card (or its error shown). The card says "Stopping…" until the
  snapshot reports the end and `heldPhysicalOperations()` shows nothing held for
  that job. Only then does it say "Stopped". With the real host, a job stopped
  mid-step ends `needsReview`, so it says "Stopped · needs review".
- **Results.** Only from `pendingResults`. Each one is inserted as a
  "Background job" message keyed by `resultID`, saved durably, and then
  `acknowledgeResult` is called. A repeated poll, or a launch after a crash between
  the insert and the acknowledgment, finds the saved message and only acknowledges.
  Stopped and failed jobs have no result; their card shows the host's note.
- **Physical holds.** After a job ends, held operations are matched to the job's
  `pendingOperationID`. A match shows "May still be running · reason" and a Release
  button. Release calls `checkPhysicalExit` and then `reconcilePhysicalExit`. A
  `retained` answer is shown with its reason. Nothing is forced, and a release
  never changes the job's outcome.
- **Workspace.** While a teammate's job is in flight (handing off, queued, running,
  stopping) or physically held, these steps are refused with "No operation ran":
  `write`, `replace`, `apply`, `integrate`, `checkpoint`, `handoff` and `release`.
  `begin` is governed by the work places (above).
- **Restart.** Cards come back from `Conversation.backgroundJobs`. Every card that
  still needs the host is re-read. If the host has no record, a card that was
  "Handing off…" becomes "Not accepted · nothing ran", and any other unfinished
  card becomes "Status unknown".
- **Follow-up.** After a receipt is saved, the owner may get a short turn (author
  Silkwire, detail "Background job follow-up") to explain it. It is queued like any
  turn, never while the room is busy, and only the owner is asked.
- **Passes.** Each teammate's PASS is its own quiet line: "Codex passed · nothing to
  add". When every open-floor reply passed, one more quiet Silkwire line says
  "Everyone passed, nothing to add." That line is not sent to teammates.
- **Builder receipts.** By default each receipt is one quiet line ("Claude finished a
  build · Ready for review") that expands on click. Settings → Development →
  "Show Builder receipt cards in conversations" (off by default) shows the full cards.

## Tests

- `BackgroundJobEndToEndTests` uses the REAL host service with a stub executor,
  opened through `BackgroundJobBootstrap`. The room's workspaces and the host share
  one private D2 registry. It covers:
  - chat during a job;
  - a second teammate delegating;
  - the same teammate messaged again;
  - Stop until a verified end;
  - posting once;
  - the conservative adapter's hold, its reason and Release;
  - a crash between insert and acknowledgement, then a restart.
- `BackgroundJobNativeBridgeTests` runs the command bridge in front of the real
  HostNativeBuilderJobs and NativeBuilder, from a teammate's finished workspace,
  and checks every refusal.
- All tests run with `SILKWIRE_TEST_HARNESS`. `HostOwnershipDefault.coordinator`
  is then a private per-process registry, so no suite can reach
  `~/Library/Application Support/Silkwire Host Ownership`.

- `BackgroundJobHostTests` checks the contract against `FakeBackgroundJobHost`. Its
  Release uses the host's real `BackgroundJobHostRecovery` over a private D2
  registry. The suite also covers titles, card labels, tolerant decoding and
  Staging snapshot isolation.
- `BackgroundJobRoomTests` uses the real store, the room and trusted workspaces on
  a synthetic repository, with scripted teammates and the fake host. Every
  teammate request runs under a parent admission from a private coordinator, so
  trusted `begin` never touches the app-global registry. The suite checks that the
  registry wasn't written.
