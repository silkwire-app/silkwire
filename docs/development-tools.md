# Project development tools

## First milestone

Trustworthy Project reading, bounded discovery, and one evidence-backed edit → build/test → shared review loop. General shell authority in conversation is not the milestone.

### Current boundaries

- Project participants share the named roots explicitly connected in Project settings. Broker requests validate current grants on every operation. Direct runtime filesystem/shell tools stay unavailable for Codex/Claude conversation transports; Eve's pre-existing OpenClaw authority is a separate boundary, not revoked by prompt text.
- Empty-root directory listing must use an independently reopened descriptor. Duplicating the pinned root shares its directory offset and causes later teammates to see a false empty directory.
- Tree/search run off the UI actor with bounded depth, inventory, files, bytes, output and time. Partial results are labelled. Searches are literal and case-sensitive; paths are relative to the named grant. Content results carry whole-file SHA-256 plus line numbers. Excluded names/content never appear in returned inventories.
- A current capability fingerprint records the snapshot dispatched to each provider, not a promise about the model's interpretation or proof that any file operation ran. Actual broker success is separate evidence.
- Codex resume retains old model-visible base/developer messages. Updating `turn/start.collaborationMode.settings.developer_instructions` alone does **not** reliably replace those messages: legacy no-read instructions and even a fresh thread's initial no-folder snapshot can still win. Before each actual turn, including broker continuations, the connector now uses the installed CLI's supported `thread/inject_items` API to append the trusted app-owned static system policy and current developer capability snapshot. No user request, quoted history or file result goes into that authoritative update. Session-start base/developer instructions are static and never freeze a folder snapshot. The existing model/effort and provider identity are preserved; runtime read-only/no-network/tools-disabled policy and unknown-tool rejection are unchanged. If the authoritative update is rejected, the user turn is not dispatched.
- Shared Builder history is no longer dropped by the room's speaker filter. All teammates can request bounded line ranges from the same conversation's last eight completed/failed/stopped build receipts. A SHA-256 identifies the exact artifact; failed exits and shortened output remain labelled. These are text snapshots already in that conversation, not filesystem paths supplied by an agent.
- Builder editing is still a separate, explicit Codex-only lane. Each task gets a unique branch and private repository/worktree copy, exact approved commands, diff and receipt. No automatic merge, push or deployment. The source checkout stays unchanged.

### Compact interface

The ⓘ beside local-save status opens context details **inside** the chat pane. It retains the recent-history explanation, per-agent last-dispatch counts/timestamps and capability fingerprints. Counts are conversation-scoped and saved across reopening; unknown old counts are not invented. Conversation options also expand in-pane, avoiding a native menu spilling beyond a narrow app window. Default chrome stays compact.

## Next coherent increments

1. **Selectable Builder owner.** Provider-specific restricted Builder adapters; separate agent grants; owner/branch/worktree shown with every task and result. Claude needs a Builder policy distinct from its chat transport. Eve requires a genuinely enforceable scoped Gateway execution path, not a prompt claiming her global tools disappeared.
2. **Project task board.** Owner, acceptance criteria, branch/base revision, status, blockers, and review outcome. Peer questions and results return to the conversation without Jason relaying screenshots.
3. **Read-only Git history and native symbols.** Broker-owned log/diff/blame with argument allowlists, no arbitrary Git command strings; then SourceKit-LSP-backed symbol/reference lookup. Neither requires shell in chat.
4. **Review interactions.** Clickable file/line references, comments tied to exact content revisions, requested revisions and explicit integration approval.
5. **Reproducible diagnostics.** Attach steps/sample data/expected behavior/build identity; publish exact-build screenshots and before/after input, streaming and UI-thread measurements as versioned review artifacts.
6. **Project notes.** Connect the actual notes/vault root explicitly, read-only. Never discover or silently grant a guessed Obsidian path.

## Preview delivery

The subsequent saved-session startup beach ball and all-agent timeout are diagnosed and fixed in [startup recovery](startup-recovery.md). Large provider resume responses are verified separately from large transcript typing.

If Silkwire Dev is open, leave its bundle and library alone. `swift Scripts/build.swift --preview` builds a production-code **Silkwire Preview.app** with a separate bundle identity; `swift Scripts/install.swift --preview` installs it side by side with a reversible backup. It uses the established library path and exclusive lock. Quit Dev before opening Preview with the owner library. Verification and installed acceptance use isolated synthetic data, not a copy of the owner's conversation.

Fresh-account onboarding, multi-provider Builders, Git/symbol lookup, task board and exact-build capture are not established by passing reader tests.

### Legacy instruction and composer repair — 2026-10-22

The live saved Codex thread retained the old blanket “do not ... read files” base
instruction despite receiving the new broker capability in its per-turn mode
settings. A synthetic fresh no-folder thread also refused a later grant under
the old transport. These are instruction-delivery failures, not failed native
folder reads; the model never requested a broker operation. The corrected
authoritative update above is checked against legacy and fresh sessions without
replacing their identities. Earlier fresh-reader acceptance did not establish
repair of already-persisted legacy base instructions.

`NativeLegacyReaderLiveTests` is opt-in (`SILKWIRE_LEGACY_READER_LIVE=1`) and creates
its own legacy no-read session, then requires actual root listing and reading an
unpredictable harmless file phrase through the native broker on the same thread.
`NativeProjectReaderLiveTests codex` covers a loaded fresh no-folder thread gaining
access, repeat listing/changed-file reads after reconnect with the same identity,
and grant revocation. Neither uses the owner's provider thread or local library.

`NativeComposer` previously compared AppKit's current string directly with the
bound draft during every SwiftUI update. Provisional prediction/IME text is not
necessarily the committed draft, so an unrelated reply/timer update could replace
it. The coordinator now tracks the last synchronized committed model text, writes
only for a real external draft change, skips marked text and safely clamps native
selection for external restoration/Send-clear. Committed native edits update the
tracking value before publishing their binding change.

`swift Scripts/test.swift NativeComposerSyncTests` mounts the real representable
and verifies provisional native text/caret, marked composition, committed edits,
external draft restore and Send-clear. The same test fails on the previous core
at the unrelated-render/provisional-text assertion. It does **not** exercise a
macOS-generated prediction or external Space-key acceptance; those remain a user
interaction check rather than an automation claim.

The combined repair is installed separately as
`~/Applications/Silkwire Updated Preview.app` with bundle ID
`app.silkwire.native.recovery.preview`. The currently running Preview is not
replaced or restarted. Quit it before opening Updated Preview: both deliberately
use the established library and exclusive data lock. Delivery hash-verifies all
nine bundle files and checks the normal installed bundle with synthetic data:
native-window quit/reopen preserves both rooms, history, drafts, attachments and
provider identities; a separate empty fixture connects all three real providers
with an externally issued read-only bookmark and no message dispatch. The live
reader acceptance above is separate from those installed-bundle checks.

## Verification for this preview

Evidence: `output/context-access/`.

- **7 core suites passed**: 40 native access/Builder checks; 22 discovery checks; 16 shared-build review checks; 18 room lifecycle/context checks; 12 connection lifecycle checks; storage and workroom persistence suites. Extreme line offsets, repeated root scans, missing grants, links/secrets, bounded/partial search, same-room artifact revocation, cross-room isolation and failed-prior-agent context counts are covered.
- **25 transport/process checks passed**, including per-turn policy payloads, preserved model/effort, revoked grants, restricted runtime boundaries, no-replay recovery and process-group shutdown.
- **Live reader acceptance passed for Eve, Claude and Codex**: start with no folders, grant scoped reads in the loaded session, list root/read an unpredictable harmless phrase, resume the same provider identity, re-list root/read changed bytes, then revoke the grant. The Eve fixture initially shortened a UUID labelled “token”; the corrected fixture labels ordinary text as a non-secret phrase. Actual file requests had succeeded; no credential-printing expectation was added.
- **Real Codex Builder passed** native read/hash-checked write → exact Swift compile → exact program-output test → recorded diff/receipt; original source unchanged. Then **each of Eve, Claude and Codex independently read the exact receipt** in its own fresh review room. Successful artifact-access events carried the matching SHA-256; no source-folder or execution grant was given to reviewers.
- **Native UI fixtures passed** for minimum-width info/options rendering, large-conversation typing/streaming, persistence reopen and composer ownership. The 12.95 MB/202-message typing fixture measured 0.57 ms p95 native edit-handler time, 128 concurrent stream chunks and 1,000 burst chunks; 3 saves while typing. Minimum-width screenshots were visually inspected. External accessibility click-through was not performed: Peekaboo reported the selected host's automation permissions unavailable; no permissions/provider settings were changed.
- **Installed normal Preview passed** real-window launch, native violet accent, exact synthetic draft/history/attachments/existing identities/context IDs, normal shutdown, and connection to all three real providers with an externally issued folder bookmark. No diagnostic startup mode or owner library was used.
- Installer hash-verified all **9 bundle files**. Owner library was byte-identical across side-by-side installation. Dev's working bundle was not replaced. Both apps deliberately share the established library and exclusive lock: **quit Dev before opening Preview**. Starting the second app while the first owns the library safely shows an error before loading/saving it or automatically connecting providers.
- The reported beach-ball incident was sampled from the existing Dev process. That sample showed an AppKit menu-tracking wait, not a demonstrated application deadlock or memory-pressure event. The trigger remains unconfirmed; the sample is retained. This preview is not claimed to fix that incident.

Reproducible commands are in the repository build/test scripts. Live reader/review suites are explicitly selected, synthetic and use existing included accounts. Fresh-account onboarding and the remaining wishlist increments above are not represented as verified.
