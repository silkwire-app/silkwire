# Teammate effectiveness — 2026-10-23

Built on combined candidate `1bf38254dbfe6a6318a2bd548389a8a16671d529`, extending the
existing host broker (`NativeRoom`, `NativeTrustedWorkspaces`, `NativeBuilder`). No new
agent tool system; every capability is a brokered response-text marker. Nothing here
installs, publishes, deploys, changes accounts, or writes live conversations.

## Fixes

**Receipts can no longer report success over a failed step.** Every Builder and
trusted-workspace command runs under `/bin/bash` with `pipefail` and an inherited
DEBUG trap that records each nonzero status absorbed by `;`, `&&`/`||`, subshells or
`$(…)` into a host-created file in the run's `tmp`. Status is `passed` only for exit 0
with an intact, empty record; `failed` for a nonzero exit or timeout; `unconfirmed`
for exit 0 with absorbed failures, a removed record, or SIGPIPE (141). `run` also
takes `checks: [{name, command}]` (1–8), each its own sandboxed process; later checks
still run after a failure. Receipts show `Evidence:`/`Absorbed:` lines and a
latest-attempt-per-command summary; the finish message states failing/unconfirmed
counts. Ari uses the latest attempt per command, keeps `unconfirmed` distinct, and
treats legacy compound commands without step evidence as unconfirmed.
Sandboxed commands now get ordinary SIGPIPE semantics (`NativeProcess
standardSignals`); provider transports are unchanged. The record is written inside the
sandbox, so a command that deliberately deletes it can only make its result less
certain, never `passed`.

**Reads no longer finish an active workspace.** `READ_PROJECT` is brokered before the
plain-reply auto-finish, and the read continuation keeps the workspace capabilities.

**Teammates keep access to receipts and diffs while working.**
- The store sends every Builder receipt in any state, with that state; the room merges
  them with its newer live copies instead of replacing them.
- The inventory lists owner, receipt status, transcript state and kind.
- `READ_PROJECT {"action":"diff","artifactId":…}` returns the complete saved diff
  (≤256 KB) from `receipt.json`, with base/head revisions; for a teammate still
  working it returns a live, read-only worktree diff marked not final.
- Final receipts produced after reconnect, revocation, close or disconnect are no
  longer dropped: the coordinator's sink is held strongly, the retired room emits
  them flagged `retired`, and the store settles only the existing entry with that
  unique ID (any conversation; never appends). On launch, entries left
  running/unconfirmed are settled from a saved final `receipt.json`.

**Baseline failures, re-checked on this Mac** (pristine clones of `1bf3825`):

| Report | Finding |
|---|---|
| RefinementTests, WorkroomTests, RoomTests failing | All pass here, individually and in the default sequence. Not reproduced; the prior helper's own sandbox (bookmark/`sandbox_extension` refusals) is the likely cause. |
| TrustedWorkspaceTests | Genuine, two defects: sandboxed `/usr/bin/swift` printed `xcodebuild` DVT diagnostics into command evidence (fresh TMPDIR = cold xcrun cache; fixed by warming the cache inside the sandbox at preparation), and a stale `steps.first` assertion left by `b76049a`. |
| NativeAccessBuilderTests | Passes (40 checks) from a checkout under `$HOME`; its home-read probe assumed that location. Outside `$HOME` that one probe now prints SKIP with the reason. |
| TrustedRoomTests, NativeEveTransportTests | Pass here; nested `sandbox-exec` and loopback work outside the prior helper's sandbox. |
| `verify.swift` LaunchServices -10827 | Environment-dependent (needs a GUI login session); see the handoff for this run's result. |

`Scripts/test.swift` now runs every requested suite, prints a summary, exits 1 if any
failed, and builds test executables at `-Onone` so a failed `precondition` reports its
file and line (the library keeps `-O`).

## Features

1. **Transfer of finished changes.** `finish` commits the private worktree to its
   private branch (host-side) and writes `transfer/changes.bundle` and
   `transfer/changes.patch` beside the receipt, recording base and head revisions,
   changed files, SHA-256s and a conflict-marker scan. `WORK_PROJECT
   {"action":"apply","fromWorkspace":…}` merges a teammate's finished workspace into
   yours after verifying the bundle hash and its prerequisite base; it reports both
   revisions, the merge base, incoming files and conflicts by path. Conflicts stay in
   the worktree for the agent to resolve; finishing records the merge commit. Applies
   are refused into a dirty workspace, from unfinished/own/unknown workspaces, from a
   tampered bundle, or across unrelated history. Jason can `git fetch` the bundle.
2. **Install in Staging (Jason-operated).** Conversation ··· menu → *Install in
   Staging…* in the working app. Candidates are built Staging apps found in this
   conversation's private workspaces, or a chosen bundle. Identity: bundle ID and
   environment, revision, source status and digest, executable SHA-256, file manifest,
   signature. Provenance: a build's `SilkwireSourceDigest` (new in `build.swift`) is
   matched to a finished workspace's committed head. *Back Up and Install* (with a
   confirmation dialog) refuses an open Staging app, an unsigned candidate, or one that
   changed since review; moves the installed app to `~/Applications/Silkwire Staging
   Backups/`, copies, verifies bytes, restores on failure, and saves a receipt.
   *Restore…* copies a backup back and keeps what it replaces. Agents have no path to it.
3. **Web inspection.** `<<INSPECT_WEB {"url","viewport","steps"}>>` for
   `staging.silkwire.si` and `staging.silkwire.app` (https only). Ephemeral WKWebView
   session; main-frame navigation limited to approved hosts; GET only; form submits,
   non-GET fetch/XHR, beacons, WebSockets and all workers (dedicated, shared,
   service) blocked and reported. Steps: click,
   type (never password fields), wait, scroll, read. Agents get text, links, step
   outcomes, console errors, blocked actions, HTTP status and the screenshot path;
   Jason gets a "Web inspection" transcript entry with the screenshot. Four per answer.
4. **Isolated site/game workspaces.** `{"action":"begin","kind":"site","name":…}`
   creates a private Git source under this conversation's Staging storage; agents work
   on it in their own workspaces, transfer with `apply`, and render with
   `{"action":"preview","path":"index.html","steps":[…]}` — fully offline (content
   rules block http/https/ws/ftp; file reads limited to the worktree). No publish path.

**Jump to active reply.** While auto-scroll is paused or off and a teammate is
replying, *Jump to active reply* scrolls to that reply's start. It does not resume
following or change the preference; *New replies ↓* still resumes.

## Limits

- Animation-driven pages may screenshot their first frame (the hidden window does not
  advance `requestAnimationFrame`); the Silkwire homepage's `?still` renders fully.
- Web/preview results and transfer evidence are synthetic-tested; live inspection of
  the two staging sites was run once, opt-in (`SILKWIRE_WEB_LIVE=1`).
- Install/recovery are tested against synthetic signed bundles in a temporary
  Applications folder only. The mounted sheet, jump button and preview rendering in
  the transcript are not visually verified.
- Model/effort switching and an Anthropic usage producer remain absent.
