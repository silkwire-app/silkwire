# North Stars first-use entry review

Reviewed candidate: Claude receipt `57951715-EEB9-4BC1-B1A5-EE1CFDDCAB74`, head `165a21b838bcf43ac7382086a759a859260704de`, base `b15af04ffce76b8e2039b0e19243ce5b63d9665e`. Applied unchanged into this private test workspace. Only this note and `Tests/FutureNorthStarsEntryReviewTests.swift` are new review files.

## Finding: first-use entry omits the editor snapshot

`Sources/Silkwire/FutureView.swift` now requires `starsEdit` to be non-nil before constructing `NorthStarsEditor` inside `.sheet(isPresented: $editingStars, ...)`. The pencil action correctly captures `future.beginNorthStarsEdit()`, assigns `starsEdit`, then presents the sheet.

However, the empty-North-Stars branch still contains:

```swift
Button("Add our North Stars") { editingStars = true }
```

That branch never assigns `starsEdit`, which starts nil and is reset to nil on dismissal. It can request presentation with no editor content. This affects the friendly Add entry on a new page and on a page with cards but no North Stars. It is separate from the stale-save protection: the safe model API can work while the first-use view entry never supplies its required snapshot.

Suggested repair for the owning integration task: have both the pencil and Add entry call one opening action that captures the immutable snapshot and presents only if capture succeeds, or use a snapshot-driven sheet. Retain the new project/page/revision save checks. Do not solve this by weakening those guards.

## Evidence and limits

The new native suite exercises actual FutureStore methods with isolated synthetic ConversationStore data, checking first-use capture/save, stale no-page rejection and preserving existing cards. A separate, explicitly source-level integration guard detects the bare Add action above and checks that the sheet still requires starsEdit. This is NOT a clicked or rendered GUI reproduction, and it does not prove the precise appearance or dimensions of any blank sheet.

The first execution passed six synthetic model controls, then failed to locate the view source because the harness copies suite files under output/tests, changing #filePath. That fixture lookup was corrected to use the repository working directory explicitly set by Scripts/test.swift. This setup error is not evidence of the view bug. The existing save-regression suite (21 checks), FutureTests and private build passed that run. A subsequent execution must reach the actual source-level assertion.

Commands to run, not advance claims of passing:

```
swift Scripts/test.swift FutureNorthStarsEntryReviewTests
swift Scripts/test.swift --reuse-core FutureDrawerSaveReviewTests
swift Scripts/test.swift --reuse-core FutureTests
swift Scripts/build.swift
```

The new source-level guard is expected to fail on this unchanged candidate until the Add entry is connected to snapshot capture. Report its real exit separately from the save-regression suites and build.

Saved diff lines 1 through 841 of 984 were supplied through READ_PROJECT in this review turn. Formal full-diff peer attestation remains pending the unsupplied final test lines; this note is a bounded finding, not whole-candidate approval. No installed Staging or stable app, owner library, real provider, permission or sign-in is touched. No installation or connected-source change is performed.
