# Staging build and verify loop

Start with a committed revision. Build with `swift Scripts/build.swift --staging`.
The candidate keeps its full source bundle and exact revision. Package it with
`swift Scripts/package-candidate.swift`; the printed directory contains **Try
This Build.app** and `candidate.json` with the bundle manifest and executable
SHA-256. This packages the existing bytes; it does not rebuild or install them.

The launcher's own source revision is recorded separately as
`SilkwireInstallerRevision`; `SilkwireCandidateRevision` identifies the embedded
app. Its window appears before validation starts. Candidate/current-app checks,
rollback discovery, quit waiting and backup/install work run on a worker queue.
The persistent window reports the phase and elapsed time; library verification
also reports file/byte counts. Quit waits time out after 120 seconds without
starting backup/replacement. Cancel is available before backup starts. Once
mutation begins, closing is disabled until completion or a reported error.
Legacy app-only backups are filtered before hashing. File hashes stream in 1 MiB
chunks rather than loading an entire library file at once.
Each chunk and file has its own autorelease pool, so Foundation read buffers are
released during the scan rather than retained for the whole worker operation.
If the installed signed app has the same complete manifest as the candidate, the
UI offers **Open Staging** and the engine returns a read-only `already-installed`
result. It does not quit Staging, scan its library, create a backup or replace app
files. The revision label alone is insufficient: different bytes still require
the normal matched backup/install operation.

The launcher also includes `Contents/Helpers/silkwire-staging-installer` for
Terminal use. Quit Staging normally, then invoke `install CANDIDATE_APP
EXPECTED_MANIFEST` with the exact reviewed manifest from `candidate.json`. This
uses the same matched backup, locks, verification and receipt path as the GUI,
prints phase progress on stderr and emits its JSON receipt on stdout. It refuses
an open Staging app or another active installer; it never force-quits either.

All shipping entry points target **/Applications/Silkwire Staging.app**: the one-click
launcher, the in-app deferred helper, Scripts/install.swift --staging, rollback and
reopen. Backups/receipts are in **/Applications/Silkwire Staging Backups**. The library
remains **~/Library/Application Support/Silkwire Staging**. Existing copies/backups
under ~/Applications are retained; the new installer does not move or update them.
Injected test paths still use synthetic libraries.

Jason opens **Try This Build.app** and clicks **Try This Build**. It asks the
installed Staging app to quit normally, then acquires its library lock. Before
replacement, the installer copies and verifies the complete Staging library and
retains the current app in the same recovery point. It verifies installed bytes
and the code signature and writes an install receipt. Stable app/library targets
and provider credential operations are absent from this path.

The in-app **Try This Build** and **Roll Back to Previous Build** actions use a
bundled helper that waits for Staging to save and exit. Rollback restores the
matched app and library, retaining newer conversations separately under **Later
Library**. Nothing is silently discarded. Older backups without a recovery-point
manifest support app-only recovery. Backup or receipt failures fail the operation;
an incomplete app is retained and the preceding app is restored when possible.

Rollback preserves the newest **Computer Control** settings, audit and task
history, including the dedicated **Keys/** folder and **disabledConnections**
Disconnect choices as one current-state directory. A deleted key stays deleted;
rollback cannot bring a historical key back while retaining newer settings.
Running tasks become blocked until Jason resumes them after checking the
current state. A historical running task cannot replay real-world actions merely
because an older library was restored. Both original histories remain in recovery
points. Ordinary install/restart task continuation is unchanged.

## Private candidate testing

```sh
python3 Scripts/agent-test.py launch 'output/staging/Silkwire Staging.app'
python3 Scripts/agent-test.py command /private/tmp/Silkwire-AgentTest-EXAMPLE '{"action":"status"}'
```

Use the actual session root printed by `launch`. The launcher makes a fresh
mode-0700 OS temporary directory and copies the candidate under the reserved
**Silkwire Agent Test.app** name. A separate bundle identity isolates macOS saved
preferences too. Re-signing changes signature bytes; the launcher records both raw
executable hashes and verifies all code/data bytes, excluding only the signature
and its Mach-O size bookkeeping. Resources stay identical; changed bundle
configuration and signature are recorded in the session receipt.
`session.json` records the original revision, source digest, executable hash,
candidate path and private process. A test bundle with missing or invalid session
configuration fails closed; it cannot fall back to Jason's Staging library, even
if someone reopens the private copy without its launch environment. The session
marker is checked against the running copy's location, revision and executable
hash and private bundle identity. A per-process request token prevents old test
requests (including Send and Quit) from replaying after reopening a private copy.

All teammates are simulated. Live account inspection, Builder sign-ins and
installation are disabled. The workspace sandbox and library both point at the
throwaway session. No owner library is copied. The test driver supports JSON
requests `status`, `switchRoom` (UUID `room`), `focus`, `paste` (`text`), `scroll`
(`fraction` from 0 to 1), `send`, `screenshot`, and `quit`. Paste uses the mounted
native text view without changing the system clipboard. Screenshot captures only
this candidate's content view. Responses and logs stay in the session directory.

The same endpoint accepts `{"action":"computer","marker":"<<COMPUTER {JSON}>>"}`.
It uses the production COMPUTER parser and an owned-window AppKit backend for
focus, click, double/right click, text insertion, scrolling, selected editing keys,
tree metadata and screenshots. Coordinates use the production global screen-point
convention; `status` returns the private content/composer/transcript frames. Text
insertion has paste semantics. `cmd+return` sends only to simulated teammates.
Host shell, filesystem operations, app launching, system clipboard shortcuts and
points outside the private content view are refused. No global input or capture
permission is required, and the live computer-control center stays disabled.

## Generic iOS Simulator runner

There is no Silkwire iOS companion in this delivery. The reusable runner accepts
an Xcode project or workspace and a scheme:

```sh
python3 Scripts/create-simulator-sample.py
python3 Scripts/simulator.py /private/tmp/ACTUAL-SAMPLE/SimulatorSample.xcodeproj --scheme SimulatorSample
python3 Scripts/simulator.py /path/App.xcworkspace --scheme App --product App.app
```

It creates a private Simulator device set and device, builds for iOS Simulator,
installs, launches and screenshots the chosen app, then shuts down its own device.
It does not use `booted`, erase existing devices or touch existing Simulator
accounts. The printed receipt identifies the runtime, device, product, launch,
build result bundle, screenshot and command log. `--keep-booted` leaves its own
device running for further inspection. Xcode and an installed iOS runtime are
required. Project build scripts run with the caller's normal host permissions.

## Nested command isolation

A broker endpoint is authority over one command's worktree and scratch roots.
Every nested launch receives a fresh endpoint bounded to its assigned roots.
Children cannot read or write ancestor endpoints, select sibling roots, or regain
ancestor authority through another hop. Host receipts include descendant launch
and exit records; cancellation closes the whole broker tree. The regression gate
uses real shell execution and kernel sandbox denials, including a child attempting
to write a sibling canary through the broker.

## Handoff

Outside Codex delivers a full-history bundle and `RECEIPT.md` under
`~/Projects/silkwire/handoffs/outside-codex/`. Claude Code's handoff is
read from the adjacent `claude-code/` directory. Verify its advertised head and
SHA-256 before fetching, review its diff from afebc70, merge it on this task's
branch, and rebuild and retest the resulting combined revision. Evidence must
distinguish synthetic teammates from live-provider checks.
