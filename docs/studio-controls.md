# Studio controls — private implementation checkpoint

## Implemented in this branch

- Project Settings: Fixed, Rotating (Round Robin), Random (Shuffle) reply order. Random is one permutation per send, not repeated random selection; every recipient remains present exactly once. The selected order is passed to the existing NativeRoom turn queue and is not recomputed during reader/workspace continuations. Rotation uses prior sent owner messages in the conversation; targeted turns count toward this position too. Existing projects default to rotating when their optional replyOrder is absent. The setting persists with the Project.
- Explicit App Settings sidebar label and Project Settings editor title.
- Tall side composer option in App Settings and conversation options. AppStorage remembers mode and writing height (240–700 points); HSplitView allows width adjustment. Below 850 points of conversation-pane width the bottom composer is used. Width persistence and mounted visual interaction have not been verified.
- Two compact provider usage rows in the sidebar. The OpenAI row uses only Codex-reported usage; it does not assert that Eve shares that account. Anthropic has no implemented usage producer. Missing/invalid/expired values display Not available rather than zero. Values older than five minutes since the Connections check are labeled stale. Clicking opens Connections. This is a connection-check timestamp, not a provider sampling timestamp.

## Verification

`swift Scripts/test.swift StudioControlsTests StorageTests ProjectTests` — exit 0, all three suites passed.

`swift Scripts/build.swift --verification` — exit 0. Tooling printed sandbox warnings; these commands still succeeded. No mounted UI inspection, installation or live provider call performed.

## Still open — not delivered by this branch

- Model/effort switching, effective-model confirmation and per-task overrides. NativeAgentTransport currently has no settings operation. Codex's send path already consumes threadParameters model/reasoningEffort, but needs supported-catalog validation and scoped settings plumbing. Claude's catalog currently returns no models/efforts. Do not add guessed model names or effort flags.
- Anthropic subscription data: requires verification of a supported route outside this no-network/no-credential workspace. No token reuse or hidden account endpoints added.
- Compact Builder activity bar (separate proposed Claude implementation); do not treat a completed compile as a mounted preview.
- Integration with earlier private table/access fixes, Staging installation, visual acceptance and everyday-app promotion are separate. This branch starts at b76049a and does not contain those private changes.

No source integration, installation, account change or deployment performed. Retain the host receipt for review.
