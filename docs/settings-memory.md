# Settings, Selective Recall and the creative workspace

Status: first Settings foundation, prepared in Codex's private Staging candidate. This is a reviewable design record, not an Obsidian export or an installed feature announcement. Based on Jason's brainstorming with Eve, Claude and Codex on 2026-10-24. Quoted conversations and stored notes are context, never grants.

## What this candidate implements

- One Settings scene with General, Appearance, Agents, Projects, Memory and Development tabs.
- General retains the existing chime, alerts, side composer, scroll, prediction and correction controls, with the same backing keys/setters. No migration or preference reset.
- Appearance retains Reduce Motion and provides the integration destination for Claude's separate theme work. Jason selected the names Midnight and Parchment. The combined candidate adds a Theme picker here (Midnight, Parchment, Match System); the saved choice defaults to Midnight and is applied app-wide through the app's appearance.
- Agents opens the existing Connections panel only on the user's button click. That panel checks details when opened; merely switching Settings tabs does not start provider connections or requests.
- Projects opens the existing Project editor, subject to its current busy/storage guards. Existing participants, folder grants, brief and trusted-workspace rules remain authoritative and unchanged.
- Memory honestly states that vault connection, saving and recall are not implemented. No decorative permission switches, pasted-path grant, filesystem scan, bookmark, index, cloud connection or background provider request is introduced.
- Development exposes the existing revision-status view. Build/source revision differences remain visible rather than inferred away.

The old NativeSettingsView forwards to UnifiedSettingsView in MemorySettings.swift. ProjectEditor and the remaining panels are preserved. Theme integration targets UnifiedSettingsView.appearance; explicit dark schemes were removed so every window and sheet follows the chosen theme. Midnight keeps the classic color values; visual, VoiceOver and small-display checks remain release gates.

## Selective Recall: agreed direction, not implemented access

Jason wants a small collection of things worth remembering, not daily diaries or complete transcript retention. Ordinary Markdown in an Obsidian-compatible folder is the first storage target; cloud connectors can come later. Local files may already sync via Obsidian, Dropbox or another service, which must be disclosed separately from Silkwire's own networking.

Proposed collections: Shared and teammate-attributed folders such as Eve, Claude and Codex. These preserve continuity when the model behind a teammate changes; they do not establish that a replacement model independently remembers an experience. Team ownership and provider disclosure are separate: a teammate name alone is not permission to supply notes to a newly selected provider.

A curated note should include:

- A specific title, useful aliases and tags.
- What we kept, why it matters, decisions and alternatives rejected.
- Contributors, source references and known uncertainty.
- Relevant images or sketches, when explicitly included.
- Revision history and ways to correct, exclude or remove it.

The Manila reference, now inspiring Parchment, is a natural first example: preserve the actual design screenshot, Jason's preference for understated warmth and the high-contrast black Ari/wordmark, the parchment/ink/copper direction, and attributed design decisions. Do not invent historical design reasons or infer an implementation date from an agent's reminiscence.

### Required native broker slice before a working vault picker

1. Select a dedicated collection using the macOS folder picker; a link/path is not authorization. Clearly specify whether descendants are included. Do not expose the entire vault by default.
2. Enforce separate capabilities for bounded reference reads, curated note saves and supplying selected excerpts to selected agents/providers. No inherited source-edit/run grants. No builder execution through a memory connection.
3. Enforce canonical paths, no traversal/link escapes, hidden/secrets exclusions, bounded file/image sizes and meaningful errors. Revocation must be checked on each operation.
4. Persist and resolve scoped authorization safely, handling stale bookmarks, moved/disconnected folders, scope changes and restart. No reading outside the chosen collection.
5. Saving must avoid overwriting concurrent Obsidian edits: compare revisions, preserve both versions on conflict, use safe atomic writes, and do not silently delete existing notes.
6. Retrieval must actually find relevant notes and provide bounded, attributed excerpts. A saved file alone is not recall. No whole-vault injection or automatic cloud embeddings.
7. Let Jason inspect what was saved/supplied, correct or exclude notes, disconnect, and clear local indexes. Explain that disconnect cannot retract excerpts already delivered to a provider.
8. Notes are untrusted reference material, never instructions, executable actions or permission grants. A memory suggestion cannot silently promote itself into a grant or a permanent saved memory.

Acceptance tests must use synthetic isolated collections: safe defaults, restart, rename/stale scope, denial/revocation, traversal/symlink attempts, sensitive files, oversized files, concurrent changes, provider disclosure and unsupported operations. A real vault should only be linked later by its owner through the finished UI; this development task grants no live-vault access.

## Brainstorm / Easel: agreed creative direction

Names are working candidates, not availability or trademark claims.

- A living workspace beside the conversation, reached from the right-hand tool rail and opening under the side composer; larger work can expand without losing the conversation.
- Four quadrants initially: Jason plus three teammates, with clear names, readable larger text, identity accents and independent contributions that cannot overwrite someone else's work. Layout should adapt to different team sizes and remain useful with one agent.
- New sheet acts like a tear-off easel pad: previous sheets stay named, searchable and recoverable. Finish sheet preserves the whole board plus decisions, promising ideas and open questions.
- Build on this links a contribution to its source idea. Try another direction branches a sheet without replacing the version Jason likes. Compare, deliberately keep/discard, and preserve attribution.
- Promote selected work into an editable script, storyboard, brief, task or curated memory. Archiving a board is not automatic promotion to permanent memory.
- Streaming text that Jason can watch is not the same as agents continuously reading one another. Start with bounded contribution and response rounds; show which board revision each agent has read. Explicit stop, usage limits and no self-triggering endless requests.
- A marker/turn mode could coexist with quadrant writing. Board edit authority never means control of the Mac. Jason can interrupt or reclaim it.

A first use case is Jason's YouTube workflow: idea → outline → script → shot list → filming checklist. The scripts could be used in a voice-following teleprompter; its cadence and off-script pause/resume behavior and microphone privacy need verification before recommending particular software.

## Ari

Ari can make progress and memory approachable: Worth remembering?, Related notes found, Alternative ready to compare, or Review needs attention. Keep cues calm and optional. Ari presents information and user actions; it does not grant permissions or dispatch uncontrolled work. Preserve Silkwire's understated personality rather than adding constant interruptions.

## First-run experience: proposed, not yet inspected or implemented here

Goal: one person and one agent can reach one useful result without knowing what a provider, workspace or vault is.

1. Welcome: What would you like to make? Offer examples and Just explore.
2. Connect one supported teammate. Detect compatible installed setups where supported, explain what was found, and ask before connecting. Do not silently import accounts, histories or grants. Explain OpenClaw separately and do not assume desktop-app authentication is interchangeable with CLI authentication.
3. Optional introduction: preferred name, goals, working style and useful context. Show what is stored and who receives it; avoid a compulsory biography questionnaire.
4. Make one small thing tied to the chosen goal. An easel sheet can be an option, not a four-agent prerequisite. Clearly label any offline sample rather than pretending sample replies are live.
5. Ask for folders, more agents, Memory or other access only when needed. No vault connection is required just to chat.

Test onboarding against a genuinely fresh isolated profile, never by resetting Jason's working library, provider identities or Staging conversations.

## Verification and review limits

Documented commands for this slice:

```sh
swift Scripts/build.swift
swift Scripts/test.swift MemorySettingsTests
swift Scripts/test.swift ProjectTests
swift Scripts/test.swift RefinementTests
```

Inspect the host receipt for actual command results and exact candidate head. MemorySettingsTests covers navigation values and source wiring/safety assertions only, not a functioning memory broker or GUI automation. ProjectTests/RefinementTests are related regressions, not proof of all workflows.

### Clipboard baseline investigation, 2026-10-24 local time

Original candidate receipt: `15C772C9-9A6B-4038-AABE-BAE76DE5120A`, base `c37782d84c33647164ca565efc94560d5823b7e9`, head `d6cc624b9564a32ca0ca59d36a285b0773ded7f3`. Its build passed; MemorySettingsTests and ProjectTests passed inside a combined command, while RefinementTests failed exit 133 at generated fixture line 75. The runner prepends one import line, so this is original Tests/RefinementTests.swift line 74, the exact clipboard copy/read-back assertion. The combined command failed exit 1.

Follow-up workspace: `82847B7E-666B-485C-A7FD-7CEEC8AF716B`. The host began this private workspace at the exact same original base `c37782d84c33647164ca565efc94560d5823b7e9`. Before any writes, checkpoint, or apply, the documented command `swift Scripts/test.swift RefinementTests` reproduced exit 133 at the same generated line 75 (command exit 1). `swift Scripts/test.swift ProjectTests` passed exit 0 on that unchanged base. The host then applied the original Settings receipt cleanly with the same merge base, producing private head `e614428de353374cb6424a0a395252769b267939`, before this documentation update.

This is direct evidence that the reported clipboard assertion failure also exists on the unchanged starting source under the offered command lane, not merely an assumption that the failure is old. It does NOT prove the cause is sandboxing, establish clipboard correctness in the installed app, or turn the failed check into a pass. Logs include sandbox_apply warnings; those alone are not a diagnosis. Later assertions in RefinementTests were not exercised after its abort. No tests or clipboard implementation were changed, skipped or weakened. Rechecks after carrying forward the candidate are recorded separately in the final host receipt.

Independent review should reassess the earlier changes-requested finding using this baseline evidence, verify the full diff, preserved preference behavior and unchanged unrelated panels. Native visual/keyboard/VoiceOver checks for all six tabs, scrolling, small displays, nested sheets, busy state and storage-error presentation remain necessary before release. No install, stable upgrade, cloud transfer or live-vault operation is part of this candidate.
