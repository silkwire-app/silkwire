# Native scoped access and Builder fixture gate

From the completed source checkout (no Node or external package dependencies):

```sh
swiftc -parse-as-library -O Sources/Silkwire/AgentTransport.swift Sources/Silkwire/Models.swift Sources/Silkwire/NativeProjectAccess.swift Sources/Silkwire/NativeBuilder.swift Sources/Silkwire/NativeProcess.swift Sources/Silkwire/NativeJSONLines.swift Sources/Silkwire/NativeCodexTransport.swift Tests/NativeAccessBuilderTests.swift -o output/native-access-builder-check
output/native-access-builder-check
```

The fixture provider emits bounded list/read/write protocol text. It does not contact a model. The test genuinely creates clean Git source, private no-hardlinks clone and worktree, runs the exact commands through the macOS sandbox, compares the source state, and checks final durable receipts. It also checks live revoke/root replacement, path/link/secrets exclusions, hash conflicts, agent-summary-only false claims, source/home/Git boundaries, overlapping storage, and descendant Stop/no replay. Temporary libraries/files contain synthetic content only.

The transport is substituted only for this fixture gate; a successful fixture gate is not a claim that a real provider completed an edit. The release integration gate must separately exercise the existing signed-in official Codex CLI and inspect its actual diff/receipt.

The acknowledgment fixture sends a terminal event before its asynchronous `send` returns and checks that no next broker turn overlaps it. A second fixture then rejects that late acknowledgment: no broker operation may execute from the premature terminal text.

The opt-in live gate is `Tests/NativeBuilderLiveTests.swift`, compiled with the same source list instead of the fixture main. Run its executable with `SILKWIRE_LIVE_BUILDER=1` only for an authorized signed-in integration test. It preserves synthetic source, a private isolated repository/worktree and `live-result.json` with exact Swift compile/run commands, output, diff and completed broker write evidence. It does not substitute a fixture provider.
