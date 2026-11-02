# Staging upgrade — 2026-10-24

Integrated Claude Photos candidate 3fa1de4 and calmer fuel-gauge candidate 839c38d from base b3b0680 into 7e30ddb. Both saved transfer bundles merged cleanly in isolated branch eve/staging-upgrade-20261024; shared Staging source fast-forwarded afterward. Everyday Silkwire untouched.

Verification: AttachmentImageTests, FuelGaugeTests, ConversationDependabilityTests, StudioControlsTests, StorageTests, RoomTests, NativeEveTransportTests all passed. `swift Scripts/build.swift --staging` succeeded. `swift Scripts/install.swift --staging` verified all 9 installed bundle files; prior bundle retained by installer. Owner workspace snapshot retained under Staging/Recovery/before-upgrade-20261024-192609. Normal application quit/reopen; no prompt replay.

Features: adaptive photo shrinking, bounded ImageIO thumbnail decode and rotation; Connections All tab; persisted sidebar pin/all choices; 30-minute idle usage refresh and 60-minute staleness.

Known separate issue: Eve transport still has a 180-second absolute turn deadline. A completed saved run is recovered by reconnect, without resend. Resume arrow only resumes auto-scroll, not networking. No new recovery/Refresh button was added (Jason clarified that request was a joke). External visual verification unavailable because Peekaboo Bridge runtime requirements were not satisfied.
