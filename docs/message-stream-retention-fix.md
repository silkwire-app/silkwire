# Reply stream reset retention — private candidate

## Scope and revision

Base: `5c48a62f9a5a2b11c0452f693e04b4b8370b5926`, the physical-exit/recovery handoff based on combined `6ca27979ea135c3476909ecc32440a54d988ded9`.

This change is confined to NativeRoom stream routing, two strict synthetic regression suites and this note. It does not implement practical ownership release, change concurrency policy, change provider transport, or modify ConversationStore/UI rendering. The inherited exit verifier's limitations remain unchanged. No running-build equivalence or attribution to Jason's recording is claimed.

## Root cause and change

A provider replacement changed the logical `run.text` but left `run.displaying` true after earlier prose. An empty replacement therefore erased the published bubble. Subsequent deltas bypassed fresh command-prefix classification, exposing split internal protocol fragments.

Every provider replacement now resets logical classification. Empty/whitespace and possible command prefixes are withheld, leaving the previous published preview visible. The next real prose is emitted as a full replacement, so it cannot append to stale preview text. Nonempty authoritative replacements still replace the entire answer.

Terminal failure/Stop must not flush a withheld command or blank reset. Terminal-state and completed-history decisions continue using actual logical text, not the retained UI preview: an empty logical completion still fails. Host-command deliberate clears and broker validation are unchanged.

The `isWithheldStreamPrefix` predicate consolidates the four existing prefix families (Project read, private work, web inspection, computer control); it is not a new permission or parser.

## Red evidence before production changes

Test-only checkpoint: `8579d63f88beba4b426e17a2029a1666e490b2d8`.

Command:

```text
env -u SILKWIRE_GATEWAY_LIVE -u SILKWIRE_GATEWAY_STAGING_LIVE swift Scripts/test.swift EveStreamResetTests EveStreamRoomTests
```

Recorded command exit 1, both suites executed and exited 1:
- Reset suite: 34 checks, 15 failures (preview retention and transient command hiding).
- Room/store suite: 30 checks, 8 failures (retention during streaming and after interruption/failure/empty completion).
- Existing correct behavior remained passing: fresh-answer replacement, message identity, honest terminal state, no duplicate dispatch, no duplicate bubble, scoped reader continuation.

Results directory: `output/tests/results/9D0F1EFC-32D8-4448-A50A-1F9727F5BC70`.

An earlier inspection grep exited 2 because it named the nonexistent `NativeAgentTransport.swift`; the definition was subsequently located in `AgentTransport.swift`. This was not a test result.

## Verification and integration

Use the final workspace receipt for exact post-fix command exits, source checkpoint and logs. Planned checks are both strict suites, existing command-buffer/transport/room/open-floor/Stop suites, and a private Staging build. A diagnostic baseline failure must not be presented as a passing fix; likewise the final passing rerun must not erase the saved red evidence.

All fixtures use synthetic provider events, a private temporary directory and (where needed) a private workspace/library environment. The valid read test reads only its own `known.txt`; failed WORK/WEB/COMPUTER marker tests never execute those commands. No live provider, stable library, installation or deployment is part of these checks.

Review/apply the small NativeRoom hunks alongside the integration owner's room changes; preserve identity-bearing exit-verifier callback wiring inherited from the base. UI pacing and cross-paragraph selection remain separate work. Validate the complete merged candidate again. Synthetic acceptance is not a live-app visual acceptance run.
