# Trusted team work in Silkwire

Jason authorized the trusted workflow in both Silkwire Staging and his working
Silkwire on 2026-10-22. The working library and agent identities stay in place.

## Normal use

Ask Eve, Claude or Codex to implement a change in the conversation. With
**Trusted Staging** enabled in Project settings and a permitted source selected,
the original speaker can create a private workspace, read/write files, execute
local build/test commands and return evidence. No Builder form, command copying
or per-edit approval is needed. Ask one teammate to implement; the others can
read its shared receipt to review the diff and command evidence.

The source must be a clean, committed Git root below
`~/Library/Application Support/Silkwire Staging/Sources`. The working app gets
an additional **Staging Source** grant; its original Project files grant is not
changed. Copy source changes into the shared Staging source only through an
explicit reviewed integration, not by editing another agent's workspace.

## Enforced boundaries

- Separate private Git repositories/worktrees per conversation, speaker and task,
  under Staging/Team Workspaces/{working|staging}.
- The host brokers `WORK_PROJECT` response text. Codex/Claude native execution
  remains disabled, and Staging Eve retains its enforced empty native tool set.
- Scoped files require relative paths and hash-checked writes. Existing files
  need their exact prior SHA-256; new files require an absent destination.
- Commands inherit the existing Builder sandbox: no network, no AppleEvents,
  no writes outside the worktree, no home/credential reads and protected Git
  internals. Local caches/output belong inside the worktree.
- Up to 128 operations and 8 MB file data per task; 256 KB per file and 900 seconds
  per command. Output and diffs have explicit truncation indicators.
- Stop terminates command process groups, including descendants. Reconnection,
  Project reconfiguration and closing the room retire its workspace coordinator.
- The conversation receives the actual diff, branch/worktree, source-preservation
  result, command output, exit codes and timeout/truncation evidence. Peers can
  read the bounded shared receipt through `READ_PROJECT` artifact requests.

Commands record per-step evidence, `run` accepts named `checks`, `finish` writes a
transfer bundle/patch, and `apply` merges a teammate's finished workspace; private
site/game workspaces and offline `preview` are available. See
[Teammate effectiveness](teammate-effectiveness.md).

Finishing retains the private workspace for review. It does **not** merge,
install, publish, upgrade the working app or send external messages. Those are
separate actions, with Jason's authorization where required. No agent should
claim integration merely because its private tests passed.

## Tests and delivered proof

The commands below describe runtime verification and promotion procedures;
they were not run by the November 9, 2026 fresh-download build-only check.
That check verified compilation of public base `c5508f3`, not these workflows.
The installed Staging target is `/Applications/Silkwire Staging.app`.

```sh
swift Scripts/test.swift TrustedWorkspaceTests TrustedRoomTests RoomTests StagingTests StorageTests NativeEveTransportTests
swift Tests/run-transports.swift
```

`TrustedRoomLiveTests` is opt-in (`SILKWIRE_TRUSTED_ROOM_LIVE=1`) and uses fresh
synthetic sessions with the real default connectors. Installed Stage acceptance:

```sh
open -g -W -n --env SILKWIRE_STAGING_CHECK=<UUID> --env SILKWIRE_STAGING_TRUST_CHECK=1 "/Applications/Silkwire Staging.app"
```

It uses only the isolated Diagnostics/<UUID> library and has each teammate
create, compile and run its own synthetic Swift program. It saves a mounted
window screenshot and real receipt checks. Reopen with the same UUID plus
`SILKWIRE_STAGING_CHECK_REOPEN=1` to prove persistence without redispatch.
These are programmatic mounted-app checks, not an external UI click-through.

## Approved working-app promotion

After testing the exact Staging bundle, quit the working app normally. Run:

```sh
swift Scripts/promote-working.swift --source-app "/Applications/Silkwire Staging.app" --target-app "$HOME/Applications/Silkwire Updated Preview.app" --library "$HOME/Library/Application Support/Silkwire Native Development" --staging-source "$HOME/Library/Application Support/Silkwire Staging/Sources/Silkwire"
```

The script requires the working app stopped and its exclusive library lock free.
It retains a verified matched app/library recovery point under
`~/Applications/Silkwire Working Recovery`. It preserves the owner's JSON tree,
changes only the active Project's trust flag/additional Staging source grant,
and never imports test conversations or sessions. The tested executable's
normalized unsigned payload and resources must match; bundle environment/name
and ad-hoc signing bytes differ explicitly. It does not launch/quit apps itself.
Later rollback must first retain newer working conversations separately.
