# Connections and compact room — 2026-10-22

## What changed

- A replacement ad-hoc-signed Dev build could reject an existing security-scoped bookmark even though ordinary bookmark resolution still found the exact, non-stale chosen folder. The prior startup catch left an open room with no initialized seats. A subsequent Connect attempted targeted recovery against a missing seat and never reset its orange UI state. This matches the reported three stuck Connecting indicators and empty account table.
- The compatibility resolver still resolves the original bookmark—not its stored path alone—and rejects stale/moved/non-directory results. It does not replace grants, follow another path, or bypass the per-operation native Project reader. It first tries scoped resolution, then noninteractive/non-mounting ordinary resolution for this unsandboxed Dev package. A future sandboxed/distribution-signed app requires its own signing/bookmark migration acceptance.
- An unavailable folder no longer blocks agent connections. It is withheld from broker capabilities and displayed separately as unavailable in Connections. Re-choosing a folder remains explicit.
- Recovery checks initialized seats, emits a terminal state even when setup never completed, preserves healthy connections, and never resends a message. Production startup is once-only, matching verification startup.
- Account inspection works without a connected room, publishes independent provider results as they arrive, and fences every inspection request so an old timed-out Refresh cannot replace newer results.

## First-time setup

Connections now presents a selected provider with its actual room status and readable reason, clear Connect/Disconnect/Stop previous actions, and provider-owned setup:

- OpenAI: explicit ChatGPT browser sign-in through the official Codex app-server managed OAuth flow; completion must be followed by an actual ChatGPT account check. Only approved HTTPS authentication hosts open. No API fallback.
- Anthropic: explicit subscription sign-in through the official `claude auth login --claudeai`, with timeout/cancellation and auth-status verification. If its browser flow cannot finish, the app explains the official CLI continuation rather than inventing an OAuth protocol.
- Eve: the existing local OpenClaw Gateway, with a clear Connect action and setup guide. It is not a separate OpenAI/Anthropic login, and its existing authority remains unchanged.

The official CLI tools/local Gateway are still prerequisites; installation guidance is visible, with no silent tool downloads. Existing subscription sign-ins are reused. Silkwire does not collect provider passwords/API keys or persist/log OAuth URLs, codes or private subprocess diagnostics.

## Room layout

The title remains editable. The header has one compact title/status/actions row; conversation search appears directly beneath it only when requested (search button or ⌘F). Agent connection status/actions live in the active Project sidebar, without duplicate header cards. The composer has a recipient/Builder/options row, then its text area with paperclip, emoji, saved/context detail and Send directly attached. There is one global Connections entry. Auto-scroll is in conversation options; paused/resume and new-replies controls remain visible when relevant. History/folder explanations are available on demand and in Help.

## Verification boundary

Focused lifecycle tests cover externally issued/invalid bookmarks, unavailable-folder isolation, repeated production startup, independent partial inspection, empty-room Connect recovery, terminal errors and draft preservation. Provider setup tests use fake executables/browser callbacks; no actual account was signed out or forced through login. Native room/search/composer fixtures are synthetic and explicitly labelled. A separate normal production-bundle test connects actual installed providers using an isolated synthetic library and a bookmark issued by a different executable; it sends no chat message. The owner's history is never copied into the test library.

Official protocol reference: https://developers.openai.com/codex/app-server (redirected to https://learn.chatgpt.com/docs/app-server when checked). The installed Codex JSON schema was also checked for managed login/cancellation/completion fields.

## Final results

- `output/connections-ux/combined-connection-tests.txt`: **12** lifecycle/bookmark checks, **43** mocked provider setup checks, **17** room checks; all passed.
- `output/connections-ux/combined-connections-ui.txt` and `combined-composer-ui.txt`: **11** combined native UI checks passed; Connections layout visually inspected. The separately reviewed compact-room contribution also passed search, paused-scroll, paste and Help fixtures.
- `output/connections-ux/existing-bookmark-probe.txt`: current production resolver restored the exact existing active Project bookmark in a read-only diagnostic; no owner content copied, no grant/library changes, no message sent.
- `output/connections-ux/release-connections-final.txt` and `installed-connections-final.txt`: both built and installed normal production bundles connected all three actual providers with synthetic data and an externally issued bookmark; no diagnostic acceptance mode and no chat dispatch.
- `output/connections-ux/installed-dev.json`: all **9** installed files hash-verified; previous package retained. `library-preservation-final.json`: owner library byte-identical across installation.

First-time account login was fixture-tested rather than forcing a real logout/account replacement. Existing actual subscription/Gateway connections were verified. No main-branch merge, remote push, public release or Gateway configuration change was performed; the canonical checkout is a local review branch.
