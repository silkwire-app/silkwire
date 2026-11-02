# Conversation dependability candidate

Baseline: `3cca712e52064b6673ab9dc601dbd73cd43a53b0`. This is the recorded installed Staging source, independently matched to its embedded source digest. The connected Project source is older (`b76049a`), and existing private workspaces remain on their original bases. This candidate does not update those source copies or install itself.

## Conversation view

The transcript keeps its view identity when the side composer crosses its responsive breakpoint. The side divider remains adjustable. Whole participant controls flow to a new line at their intrinsic widths. A logical visible-message anchor is measured from row frames and restored after window resize while following is off; it preserves the message, not an exact pixel within rewrapped text. Lazy rows remain enabled for long histories.

Tables use the actual available width, distribute extra space by bounded content weights, measure wrapped cells at those widths and paint one continuous background per row. Streaming replies use the same Markdown renderer as completed replies; incomplete delimiters can remain visible until their closing text arrives. Divider rules and multi-backtick table spans are parsed. Fenced text and Copy code retain original bytes. The native composer disables automatic quote, dash and text replacement; optional spelling correction remains a separate user preference.

Allowance colors describe remaining allowance: green >=75%, amber >=25% and <75%, red <25%. Missing/invalid/reset-expired values are neutral. Samples older than five minutes or without their own provider timestamp are neutral and labelled stale when a percentage exists. Another provider's check cannot refresh them. Usage availability does not depend on a connected seat, and connection health never invents usage. Anthropic still has no new usage producer in this candidate.

Workspace activity names the host operation. Each initial reply prompt contains its actual ordered targets, one-based position and final-speaker flag. Shuffle uses the actual dispatch order. A final speaker can still have incomplete work; the flag is not a completion certificate.

## Private development workflow

Connections and Context expose running/installed Staging revisions, read-only connected-source snapshots, and observed workspace base/head receipts. Silkwire source mismatches are flagged; divergent revisions do not imply which is newer. Reconnect refreshes the teammates' source revision snapshot; `begin` always records its real base.

`WORK_PROJECT begin` accepts optional `taskTitle`, `paths` and `taskId`. Omitting paths reserves the whole source. A host-owned conversation task board refuses overlapping active scopes, shows owner/status and persists across reconnects. `board` reads it. After finish/stop, `handoff` with taskId/to reserves the same task for its named recipient; their `begin taskId` accepts it. `release` with taskId/reason releases only the speaker's own inactive assignment after an interruption. Claims coordinate assignments; they are not extra OS file grants and cannot prove arbitrary shell edits stayed within a declared task scope. Each workspace remains a separate repository.

Existing `apply` transfers finished teammate changes for preparation. `READ_PROJECT diff` still reads live work read-only and labels it non-final. For reviewed integration:

1. Another teammate reads all pages of the finished, untruncated diff through `READ_PROJECT diff`.
2. `WORK_PROJECT review` supplies fromWorkspace, exact headCommit, diffSha256, decision (`approved` or `changesRequested`) and summary. The host records line coverage and refuses self-review, unread diffs and unresolved/incompletely scanned conflicts. This is a review attestation, not a test certificate.
3. `WORK_PROJECT integrate` verifies that exact head/diff's independent approval, then uses the existing merge/conflict machinery in the caller's private workspace. A successful integration records the review in its host receipt. Connected sources remain unchanged.
4. Edit/integrate → `checkpoint` → run build/tests → finish. Checkpoint commits only the caller's private source while leaving operations available. This lets the app build record the exact clean candidate head before finish. Any subsequent source edit requires another checkpoint and build.
5. Jason can inspect the existing Install in Staging UI with candidate identity, backup, recovery and installed-byte confirmation. This pass never invokes it. It is not an automatic approval gate for all tests or a replacement for independent human review.

Task/review records live outside the command-writable worktree. Review coverage does not survive a reconnect; read again rather than inventing coverage. Saved approvals bind the exact head/diff. An abandoned active task requires explicit owner release. Host record write/read failures refuse operations or are reported as taskBoardError; they are not silently considered success.

## Web capture and native visual checks

Inspection separately reports requested/final URLs, redirect destinations, HTTP status, resource readiness, snapshot errors and near-uniform-dark captures. If an approved redirect drops explicitly requested `still`, one bounded GET retry restores it on the approved final host. The observed `.app/?still` redirect drops the query; `.si/?still` does not. The offscreen capture window is ordered to provide WebKit a compositing surface, waits for bounded image/font settling and a paint, then snapshots after screen updates. Uniform-dark output triggers one retry and a warning rather than a visual-success claim. Oversized screenshots are reduced to the inline budget. Transcript images are large, expandable previews labelled with the requesting teammate. Existing worker/network guards remain in place; this change does not certify those guards as a host-enforced universal request boundary.

Verification bundles default to a clearly labelled synthetic resize fixture, a new temporary library and disconnected agents. They refuse Application Support libraries, linked library files and existing unmarked conversation libraries. Default/design/resize account checks do not start providers. Explicit live acceptance modes remain opt-in. `swift Scripts/verify.swift resize` exercises six window sizes and captures native images; inspect its receipt, which can fail, and the images. Unit suites do not substitute for these mounted checks.

## Verification limits

Exact command exits and current evidence are supplied with the candidate handoff. The restricted execution environment denies nested sandbox_apply, process listing, some security-scoped bookmarks and WebKit/LaunchServices services. Failures remain failures; test isolation is not relaxed. A skipped opt-in live suite is a skip even if the legacy runner exits zero. Source integrity, signatures and a selected green gate identify a reviewable artifact; they do not certify the full end-to-end protected workflow or permission to install.

An independent Claude Code review and unrestricted regression gate are required before installation consideration. Do not use this document as installation clearance.
