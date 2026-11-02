# Silkwire foundation

## Approved direction (Jason, 2026-10-22)

- Native Apple application; Swift owns UI, persistence, lifecycle and coordination. Target **100% Swift application code** using supported external integration protocols. A non-Swift SDK boundary requires evidence of necessity, documented costs and Jason’s decision; it is never silently inherited.
- Independent source repository in `~/Projects/silkwire`, not a renamed or hosted part of another product.
- No Node helper layer, predecessor runtime discovery, web host, React/Vite dependency or inherited web database.
- External agent services/official CLIs are integration boundaries, not the app implementation. Keep current accounts and included-usage checks, with no API fallback.
- Reuse vetted ideas, algorithms and tests deliberately. Do not defer foundational coupling as "fix later".
- Preserve existing design masters and the owner's native library, drafts, attachments, Projects and provider sessions.

## Release invariants

Native UI/storage/context/coordination/file broker/Builder are Swift. Provider lifecycle acknowledgments are not completion. Drain output before terminal persistence; Stop terminates owned process groups, with no automatic replay. Reading is shared by Project participants; Builder editing/execution is separate and explicit. File contents are untrusted data. Build in a private branch/worktree copy; return exact commands, output and diff; no automatic merge/push/deploy.

Normal app termination synchronously kills any remaining owned local process groups after saving. It cannot depend on a delayed kill Task running after the app has exited. Gateway remains an external service; closing the app never kills the global service or silently replays its pending run. An interrupted/unconfirmed task is labelled honestly when reopened.

The app package invokes Apple's compiler with a workspace-local module cache; no external Swift packages or shared build service are needed. Inside Builder only, `SILKWIRE_COMMAND_SANDBOX=1` lets the build script disable the compiler's redundant nested sandbox for Apple SwiftUI macro subprocesses (macOS rejects nested `sandbox_apply`). Those subprocesses still inherit the unchanged outer command sandbox: network denied, source/home writes denied, private worktree/tmp writes only. The flag does not grant access or weaken the outer policy.

Typing must not synchronously serialize the full library. Checkpoints run on one serial writer off-main, with critical send/final/switch/quit saves ordered behind them. Streaming text coalesces before rendering and flushes at terminal boundaries. Historical rows are lazy/equatable; preview images are cached. Performance gates use a synthetic libraries at the originally measured size (~8 MB, 160 messages) and a larger ~13 MB/200-message native UI fixture, including typing while streaming, not only tiny visual fixtures.

Production releases exclude diagnostic fixtures. Tests use isolated libraries and synthetic files; no production/customer data is sent.

## Component contracts

See `Sources/Silkwire/AgentTransport.swift` for the provider boundary. All callback identities must remain scoped to their current room and request. NativeRoom owns participant ordering, bounded shared history, generated current capabilities and hidden file-read continuations. NativeProjectAccess enforces current folder grants on every operation. NativeBuilder creates its own source copy and records actual execution evidence.

## Deliberate decisions

### Native app versus external agents

**Choice:** all application-owned implementation and build/test/install scripts are Swift. Eve connects through the published Gateway v4 protocol; Codex and Claude connect through their official external CLI interfaces. No vendor SDK wrapper is needed for these current integrations.

**Cost/boundary:** the external tools and model services remain separate products, not implementations rewritten in Swift. Their sign-in, protocols and availability remain integration dependencies. In particular, Eve's existing OpenClaw tool authority is not revoked by a conversation-only prompt; the native Project broker's grant checks are a separate enforceable boundary. See [the Gateway contract](native-gateway.md).

**Revisit:** when a provider changes its supported protocol, or before adding another platform/provider. A proposed non-Swift SDK helper needs concrete necessity, alternatives, packaging/performance/maintenance costs, and Jason's decision.

### Preserve the library, separate the source

**Choice:** new independent Git repository in Jason's chosen Silkwire folder, without importing predecessor Git history or build/runtime discovery. Retain vetted native UI/storage algorithms, the existing Silkwire-only JSON schema, dedicated library path and established macOS bundle identity (`app.silkwire.native.ready.preview`).

**Cost/boundary:** the established library name includes “Native Development”; this is an intentional compatibility path, not a dependency on another product. The established bundle identifier is also retained intentionally so existing macOS app preferences/permissions are not gratuitously reset. Neither compatibility identifier performs a predecessor lookup. Changing storage paths/schema or app identity merely for naming would create avoidable migration and UX costs. Never silently reset grants, sessions, drafts or history.

**Revisit:** before a production bundle or multi-device storage migration, or if the library reaches 50 MB / a measured critical save exceeds 100 ms. Backup/export/recovery acceptance comes first; this is a concrete storage review gate, not a promise to ignore growth.

### Composer ownership

**Choice:** save the submitted message and attachments before dispatch; clear their composer copies on room acceptance, not after agents finish. A rejected send retains its draft, and later completion/failure never erases the next draft.

**Cost/boundary:** an accepted message with failed/unconfirmed replies stays labelled in the transcript. There is no automatic resend.

**Revisit:** only with an explicit message editing/retry design, including duplicate-delivery protection.

### Native brand resources and build isolation

**Choice:** keep the approved static macOS icon/accent resources alongside their source and a source/artifact/toolchain SHA-256 manifest. Normal builds verify every input/output hash and fail on drift before compiling; use `Scripts/regenerate-brand-assets.swift` for an explicit trusted asset-authoring step.

**Cost/boundary:** this installed Apple asset toolchain delegates to daemons/global scratch paths and cannot run within the general Builder's private-write sandbox. No supported redirect was identified. We preserve native violet accent styling and the icon without widening Builder authority, dropping styling, or relying on undocumented daemon switches. The compiled files are ordinary native resource data, not non-Swift app/helper code. A text-only Builder cannot silently regenerate brand binaries.

**Revisit:** whenever icon/catalog sources change, during Apple toolchain upgrades, or before adding new generated resource types. The hash guard makes this an explicit asset-build step, not silent stale-resource debt.
