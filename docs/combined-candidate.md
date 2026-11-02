# Combined Staging candidate — 2026-10-23

Integration base: `b76049aed2507cdaabde398669b04f54e8676b16` from the independent Staging source clone. The integration repository is a separate full local clone, with a separate `integration/staging-combined-20261023` worktree. No original workspace was edited. No app was installed or published, and no live conversation library was changed by this work.

## Verified imports

All four packages were uncommitted changes against the same base, not finished commits accessible by abbreviated branch names. Their actual Git diffs and untracked source/test files were inspected and imported. Receipt IDs:

- Eve `6193EBA3-E7F8-47C7-A97F-B47E2B997B4D`: pipe-table parsing/rendering and parser tests.
- Eve `9682CBEF-545D-448F-9950-3EE41D737AB8`: optional tall side composer, remembered height/mode, narrow-pane fallback, App/Project Settings labels, Fixed/Rotating/Random reply order, provider usage HUD and tests.
- Claude `BD2A736B-45EC-401A-891D-F82D27975913`: collapsed Ari Builder activity bar, receipt disclosure/copy, compact shared-history summaries and tests.
- Claude `90C4656A-043B-4676-B2D5-1CECAF1FABD9`: successful folder-access evidence retained on reconnect.

The patches apply without textual conflicts. ConversationStore and SilkwireApp contain contributions from multiple packages; they were integrated together rather than copying either whole version over the other.

## Recorded review findings addressed

Ari counts **commands**, with standalone documented test-command results shown separately. It supports both host receipt formats, ignores fenced logs, treats missing exits as unconfirmed, respects nonzero exits over a contradictory label, and treats unknown/cancelled outcomes conservatively. Its running bar has a Stop control bound to the current receipt/task through the existing stop paths. Historical receipts cannot stop unrelated work. A successful shell wrapper still does not prove every command inside it passed; that host-broker issue remains for the next development step.

Access evidence distinguishes listings from file reads and records a timestamp. Successful evidence is stored per Project and exact folder grant, survives reconnect/relaunch, and is explicitly labeled historical rather than proof of current access. Replacing or revoking a grant or removing a participant invalidates it. Failed operations show failure while retaining the last successful evidence. Existing hidden-entry/partial-scan disclosures remain available. Tests use synthetic events and libraries for every agent; live provider access is not claimed verified.

## Missing or unverified

- No implemented jump-to-active-reply control was found in the private diffs/workspaces. The existing New replies control is retained; it resumes following and is not the proposed independent jump control.
- Model/effort switching and an Anthropic usage producer are absent. The HUD honestly displays unavailable values. OpenAI data comes from the existing Codex connection, not a combined Eve/Codex allowance.
- Side-divider width persistence, mounted interactions with the new tables/Ari/side composer, and the complete inside-app development bridge remain unverified or unfinished.
- No teammate-change-transfer API, Jason-operated install flow, web inspector or writable web workspace was added in this combine step.

See the standalone handoff and evidence next to this candidate for exact source revision, commands, exit codes, baseline comparisons, artifact hashes and next steps. Earlier `studio-controls.md` is the original private-package checkpoint; this document describes the combined source.
