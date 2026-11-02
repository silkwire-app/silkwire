# Larger sidebar Ari and wordmark

Jason requested the larger proportions in his Claude.app reference: the wire should be approximately the search bar's width, not a small mark floating above it.

## Minimal production change

In Sources/Silkwire/SilkwireApp.swift, remove the sidebar AriWalkingMark's 200 pt maximum-width cap and use the search field's existing 14 pt horizontal inset. The complete vector mark (Ari, wire and outlined SILKWIRE lettering) scales together with its existing aspect ratio. No artwork, global typography, animation cadence, hover behavior, theme colors or Reduce Motion behavior changes.

At sidebar widths 245 / 278 / 350 pt, the mark's proposed widths become 217 / 250 / 322 pt, rather than at most 200. The strand's original edge fade and small canvas margins remain; its geometric span is more than 95% of the search field width. Normal ideal-width size rises by 25%, while a wider sidebar gains more. The name is part of AriWalkingMark's canvas, so changing SilkwireBrandTypography.wordmarkSize would not fix this header.

This patch is based on running revision 59ab7de and deliberately contains no storage or conversation-flow changes. Apply only this small sidebar sizing hunk when combining with later reviewed candidates; do not replace the entire older SilkwireApp.swift over newer work.

## Checks and limits

Tests/SidebarBrandSizingTests.swift checks the actual caller binding (no 200 pt cap, matching inset and retained motion arguments) plus original layout geometry in graphite and silver at all three supported sidebar widths. This is not a screenshot or pixel-equivalence assertion.

Run existing AriWalkTests, BrandMarkTests and BrandResourceTests alongside the new suite using Scripts/test.swift. Build the private Staging candidate using Scripts/build.swift --staging. Actual exits in the host receipt, not this document, establish pass/fail. No installation is part of this task.

Native visual review should check narrow and wide sidebars, both appearances, search/header spacing, hover and Reduce Motion against Jason's supplied reference. Until that review is recorded, do not claim an exact visual match or installation.
