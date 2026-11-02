# Developer notes

The original developer README, kept for the detailed build, verification and Staging notes.

## Build and review

Requires the Apple Swift/Xcode toolchain and macOS 14+. External agent connections use the installed official Codex/Claude CLIs and local OpenClaw Gateway with existing sign-ins; these tools are not bundled or rewritten. No API-account fallback.

```sh
swift Scripts/build.swift
swift Scripts/install.swift
```

The packaged app is `output/release/Silkwire Dev.app`; installation updates `~/Applications/Silkwire Dev.app` with a reversible full-bundle backup. The installer refuses to replace an open app. Existing bundle identity, library, drafts, attachments, Project grants and provider identities are retained.

Packaging uses Apple's compiler and a local module cache. `Package.swift` supports editor indexing. Static native icon/accent resources are source-hash locked; if their authoring sources change, explicitly run `swift Scripts/regenerate-brand-assets.swift` in the trusted asset workspace and review its resource diff. Ordinary Builder commands do not need Apple's global asset-compilation daemon/temp access.

## Verification

```sh
swift Scripts/test.swift
swift Scripts/test.swift NativeAccessBuilderTests
swift Tests/run-transports.swift
swift Scripts/test.swift NativeEveTransportTests
swift Scripts/build.swift --verification
swift Scripts/verify.swift
```

The separate verification app uses synthetic isolated libraries, never the owner library. Real-provider integration is opt-in and uses synthetic content and existing included accounts:

```sh
swift Tests/run-transports.swift --live
swift Scripts/verify.swift workroom workroom-reopen
```

Reading is shared by Project participants. Builder editing/execution is an explicit separate grant; private source copies return actual diffs, exact command results and durable receipts. No automatic merge, push or deployment.

See [architecture and decisions](docs/architecture.md), [Gateway boundary](docs/native-gateway.md), and [verification results](docs/results.md).

Latest connection regression, provider setup and compact-room changes: [review notes and verification](docs/connections-and-room.md).

Saved-session startup beach ball and independent provider timeout recovery: [diagnosis and verification](docs/startup-recovery.md).

Current scoped reader, Project tree/search, shared Builder evidence, compact ⓘ panel and side-by-side Preview: [development tools and verification](docs/development-tools.md).

Independent experimental app with its own library, provider sessions and private
source clone: [Silkwire Staging](docs/staging.md). The legacy Preview still uses
the working library; it is not the isolated Staging environment.

### Computer control (Staging)

[Computer control](docs/computer-control.md) lets Eve, Claude and Codex see the screen,
click, type, open apps, read UI trees and run unsandboxed commands as Jason in the
installed Staging app. They drive only when Jason is idle, and his input pauses them.
Durable tasks continue without Pass. There is a short ask-first list and an audit log.

### Trusted team work

[Trusted Staging](docs/trusted-staging.md) lets the original room teammates edit,
build and test in independent private workspaces, including from the working
app. Results return to the same conversation; installation/integration remain
separate from private execution.

Teammate effectiveness — truthful per-check receipts, shared receipts/diffs while
working, change transfer, Jason-operated Install in Staging, web inspection, private
site/game workspaces and Jump to active reply: [notes and verification](docs/teammate-effectiveness.md).

One-click Staging candidates with matched app/library recovery, private candidate
tests with simulated teammates, task-scoped nested brokers and generic iOS
Simulator tooling: [build and verify loop](docs/build-verify-loop.md).
