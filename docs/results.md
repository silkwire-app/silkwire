# Independent native Swift foundation — 2026-10-22

## Delivered implementation

- Canonical independent source: `~/Projects/silkwire`. Existing design masters untouched; no predecessor Git history imported.
- Swift owns interface, persistence, queues/context, file access, Builder and provider transports. Native Gateway WebSocket and official external CLI integrations; no app-owned Node helper, build lookup or runtime fallback.
- White spider and bundled Archivo wordmark retained. Shared Project reading, named roots, pinned brief and separate Builder grant retained.
- Draft checkpoints encode/write off-main on one serial queue; partial replies coalesce; rows are lazy/equatable; decoded preview images are cached.
- Submitted composer text/attachments clear on room acceptance, not after replies finish. Rejection retains draft and healthy connections; later completion/failure cannot erase the next draft.
- Malformed/multiple reader envelopes execute nothing and receive bounded correction. UUID folder IDs are canonicalized; actual current grants remain authoritative.
- Stop and normal host termination clean up owned local process groups. No automatic replay. Builder continuations require both terminal evidence and send acknowledgment before another broker operation.

## Gates and evidence

All tests use synthetic data and isolated libraries/source. Existing provider sign-ins are reused without credential copies or API fallback.

| Gate | Result / evidence |
|---|---|
| Storage, Projects, refinement, workroom model, persistence performance, native room, access/Builder | 7 Swift suites passed: `output/final-swift-suites.txt` |
| Native room lifecycle | 17 checks, including malformed-request correction, acknowledgment ordering, targeted recovery and immediate Stop |
| Scoped access/Builder fixtures | 34 checks: revoke, inode replacement, symlink/secret/binary boundaries, hash writes, real private Git/commands/diff, Stop and no false edit claims |
| Process/CLI protocol | 24 checks: `output/process-final.txt`; includes partial-pipe failure, output drain, cancellation, saved-turn recovery and host-shutdown descendants |
| Gateway protocol | 14 checks: `output/gateway-integration.txt`; plus 2 synthetic live checks during transport implementation |
| Existing-plan CLI integrations | 10 live checks during transport implementation: fresh and same-identity resumed Codex/Claude replies |
| Native editor/composer/reopen | 20 native checks across 3 modes: `output/native-ui-final.txt` |
| Real native shared reading + brief + isolated Swift edit/build/test + Stop + reopen | 17 checks across 2 modes: `output/native-workroom-final.txt` |
| Full Silkwire source through Builder | Actual native app compilation, resource packaging, ad-hoc signing and strict signature verification passed in a private worktree; canonical source unchanged: `output/native-source-build.txt` |
| Brand resource integrity | Source-palette drift and compiled-catalog corruption both fail closed before compilation: `output/final-package-tests.txt` |
| Installed app | Native window, bundled violet accent and normal shutdown; fixture Projects/history/draft/attachments/session IDs preserved: `output/final-package-tests.txt` |
| Installation | Signed package, all installed files hash-verified, previous bundle retained: `output/installed-dev.json` |
| Owner library | Byte-identical across installation, established app identity retained: `output/library-preservation.json` |

The typing test uses the actual mounted `NSTextView` while a synthetic reply streams, plus a 1,000-chunk burst and durable reopen. The ~12.95 MB /202-message native run measured a 0.59 ms p95 edit handler and kept all typed/streamed text. `performance.json` also records cadence measurements. Handler time is **not** an end-to-end display-latency or frame-rate claim. The unit persistence fixture retains the original ~8 MB /160-message baseline.

The real Builder changed only synthetic `greeting.swift` through completed native read/hash-write operations. Exact Swift compilation and execution passed; original source unchanged. Model summaries were not accepted as execution evidence. Full native source verification is recorded separately by `NativeSourceBuildTests`.

## Intentional boundaries

- External agent runtimes/services remain external dependencies. “Swift throughout” describes app-owned code, not the implementation languages of Codex, Claude or OpenClaw.
- Eve's existing Gateway authority is not revoked by a prompt; scoped Project access is separately enforced by the native broker. See the Gateway boundary document.
- The existing native JSON library and macOS identifier remain for continuity, not as predecessor infrastructure. No owner history was imported into tests or reset.
- No merge/push/deploy is performed by Builder. Isolated changes require review. Development installation is local, not a public release.

Initial failed integration receipts were retained under `output/`: Claude emitted two reader envelopes together; the strict parser rejected them. The correction preserves strict parsing and gives bounded no-operation feedback. The installed smoke harness initially selected a small auxiliary window; it now checks the actual full-size native window. These initial failures are not counted as successful gates above.

The full source-build gate also exposed global Swift-package caches, nested compiler macro sandboxes, and daemon/global-temp native resource compilation. Packaging now invokes Apple's compiler with a private cache; macro children retain the outer sandbox. Static brand resources have source/artifact drift guards and an explicit trusted generator. The final full build passed without widening source/home/network permissions. See the architecture decision for its maintenance boundary.
