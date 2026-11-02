# Independent room concurrency re-review

Candidate: Claude receipt F973EBB8-1C98-4ED4-B095-DF721F782F46, head `1a5c89e4d61488dcaff89248337f09cad4a426bd`, based on `b15af04ffce76b8e2039b0e19243ce5b63d9665e`.

The complete 696-line saved candidate diff was read before this re-review. It rejects exact duplicate live request strings and marks all turns cancelled before independently awaiting their transport Stop calls. This private review copy applies that candidate unchanged. The only new files are this note and `Tests/BackgroundRoomIdentityReviewTests.swift`.

## Additional synthetic coverage

The new suite checks identity reservation before a transport acknowledges Send, preservation of the original request after duplicate rejection, retrying an unadmitted request after a busy seat becomes idle, and sequential cancellation while both concurrent Stop acknowledgements are held. It also checks that stopping seats remain occupied, queued work never starts on late completion, and cancelled queued seats accept fresh work afterward. Continuations are explicitly released, with bounded waits and fixture cleanup.

Run through the documented native harness:

```
swift Scripts/test.swift BackgroundRoomIdentityReviewTests
swift Scripts/test.swift --reuse-core BackgroundRoomIsolationReviewTests
swift Scripts/test.swift --reuse-core BackgroundChatReviewTests
swift Scripts/test.swift --reuse-core RoomTests
swift Scripts/test.swift --reuse-core OpenFloorTests
swift Scripts/test.swift --reuse-core OpenFloorStopTests
swift Scripts/build.swift
```

The first run of the new suite reported 12 passed and 1 failed: the fixture incorrectly required a delta for the first visible words. Source inspection confirmed that NativeRoom intentionally publishes those first words as replace. Only the test was corrected to accept either visible-word event while still requiring exactly one matching event with the exact request and teammate. The original isolation, background chat, room, open-floor and Stop suites and private build all passed that initial run. A subsequent run must verify the corrected final source. The final host receipt records actual exits and output; the earlier fixture failure is not a production fix or a passing result.

## Identity observation

NativeRoom validates UUID syntax but compares live request IDs as exact Strings. The inspected ConversationStore routing also compares request Strings, rather than parsing them into UUID keys. Therefore differing letter case is not established as a downstream identity collision by this review; normalization is not presented as a reproduced blocker. Future consumers that use UUID-valued keys must define and enforce a consistent identity representation at admission.

## Verification limits

Synthetic transports perform no real provider, broker, network, account or installation operation. Passing these checks would verify the room boundary only. It would not demonstrate that the composer accepts multiple active requests, that the same busy teammate can converse through a separate background session, or that durable background execution is integrated. ConversationStore in this base still has a single activeRequest and filters incoming deltas against it. No Future drawer fix is included. No source integration or installation is authorized or performed by this review.
