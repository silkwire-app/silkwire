# Bounded Codex reconnection — 2026-10-24

## Cause

Owner Staging Codex reconnect failed with `Codex event exceeded the local bound`. Valid included ChatGPT sign-in was confirmed using the connector's exact CODEX_HOME (`~/.codex`). The saved rollout was about 90 MB on disk. The connector requested `excludeTurns: false` on resume, followed by a second full-history `thread/read`. Its per-frame JSON bound is 36 MiB; image/history expansion could exceed it. On-disk size is not RAM or model context usage.

## Fix

- Resume with `excludeTurns: true`; metadata read uses `includeTurns: false`.
- Normal reconnect loads no historical turns if no pending turn needs recovery.
- Uncertain-turn recovery locates the exact saved turn using newest-first pages of 50, `itemsView: notLoaded`; at most 200 pages, with repeated-cursor detection.
- Only a terminal selected turn loads items, one per page, filtered by its exact turn ID; retain only agent message text. Max 512 pages and 1 MiB recovered text. Never retain user/image payloads in recovered output.
- Stop Previous uses the same bounded path, exact turn IDs, and terminal-state recheck. It never resends a turn, clears an unresolved identity on errors, logs transcript content, or replaces an established thread.
- The existing 36 MiB frame bound remains unchanged. Missing exact turns, foreign items, malformed pages and repeated cursors fail closed.

Official protocol: https://developers.openai.com/codex/app-server/ . Installed 0.164.0 JSON schemas also confirm `thread/turns/list` and `thread/items/list`, including nested item entries and turn IDs.

## Checks

36 standalone transport/process checks passed, including history larger than the frame bound, exact older-turn pagination, item pagination, Stop Previous of an already completed reply, missing exact turn, cursor loop, foreign item, active-thread guard, identity preservation, runtime-tool denial and no replay.

A read-only connection check using the actual owner Staging saved session reconnected in 6.04 seconds, preserving its identity and sending no user turn. NativeJSONLinesTests, RoomTests and StorageTests all passed, and the final Staging build succeeded. The first core/build attempts were invalidated when the Stop Previous fix changed an input during compilation; clean final reruns passed. The installer verified 9 bundle files and preserved the library. Installed executable SHA matches the final built bundle.

## Separate scope

No history deletion or model-context compaction. Shared prompt history already limits itself to the last 30 visible messages and limits individual messages; that is distinct from provider-history transport. The existing Eve absolute 180-second deadline remains a separate issue. Stable/everyday Silkwire and shared sign-ins are not modified.

## Installed verification

Owner conversation count, exact draft and Codex thread identity are unchanged against `Recovery/before-paged-codex-20261024-193954/workspace.json`. Normal Staging quit/reopen; full prior app bundle retained by installer. Source integrated at 39e456f.

A Staging process was running from an older backup bundle (`Silkwire Staging Backups/2026-10-24T17-32-45Z-before-install-499DE5FF`) before this installation. After quitting it, launched the exact installed path with `open -n`; verified running PID 57105 used the then-current per-user installation. This is a historical October 24 record, not the current install location: the current target is `/Applications/Silkwire Staging.app`. Everyday Silkwire PID 1909 remained untouched. Avoid assuming a running app with the same bundle ID is the newly installed executable.

External UI verification remains unavailable: Peekaboo on the active Mac node could not access the Staging window. Real connector recovery was verified separately without sending a turn; do not represent this as a Send-button click-through.
