# Silkwire Staging

## Working agreement

Work in the dependable installed Silkwire. Experiment in **Silkwire Staging**.
Be bold inside Staging and protect everything outside it. Jason reviews Staging
before any stable upgrade. This setup does not replace or rename the running app.

| Boundary | Staging |
|---|---|
| Bundle | `app.silkwire.staging`, orange STAGING title, STG Dock badge |
| Library | `~/Library/Application Support/Silkwire Staging` |
| Source | Independent full Git clone under that library's `Sources/Silkwire`; no origin, alternates, shared Git directory or hardlinks |
| Conversations | Point-in-time historical copy; fresh Project, room, message and provider-session identities |
| Folder permissions | Original grants removed; only exact original Silkwire source matches receive a new grant to the private clone |
| Provider working directories | Separate `Runtime/Provider Processes` under Staging |
| Builder receipts and copies | Separate `Builder Runs` under Staging |
| Sign-ins | Existing included accounts reused; credentials are not copied. Do not reset shared sign-ins as an experiment. |

Staging ignores the legacy `SILKWIRE_DEV_DATA` override. It refuses library
paths outside its own root/Diagnostics, folder grants outside its private
Sources descendants, and symlinks escaping those sources. These app-owned
checks do not claim to sandbox arbitrary code Jason runs outside the app.

## Eve is restricted by the Gateway, not by a promise

Staging Eve uses `agent:main:subagent:silkwire-staging-<room UUID>`, never the
working `silkwire-native-dev` room. Before connecting/sending, the app sets and
checks read-only permission and `inheritedToolDeny: ["*"]`, then requires an
empty effective tool inventory. Unconfirmed policy, exposed tools, or warning
notices block sending. Staging uses the supported direct `agent` RPC rather
than command-interpreting chat dispatch. A developer-level instruction permits
plain response-text Project requests; it does not grant runtime tools or file
operations. The installed
Codex harness applies inherited policy to its native shell/execution/features
as well as OpenClaw tools. No main-agent configuration or account is changed.
Operator admin scope is needed on the existing local token to apply this
session-specific restriction; absent scope fails closed.

Codex/Claude native runtime tools remain disabled. Plain-text Project reads
and trusted private edits/builds/tests are brokered by the host app; see
[Trusted team work](trusted-staging.md). Every provider receives automatic STAGING context, independent of briefs.

## Import for existing owners

This imports an existing working Silkwire library; it is not first-time setup
for someone with only a fresh clone. It requires a valid `workspace.json` with
conversations and Projects in the source library, a clean committed source
repository, and a destination Staging library that does not already exist.
The importer reads the existing working library, so use it only when that
import is intended. The November 9, 2026 fresh-download check did not run this
procedure or inspect an owner's library.

There is no supported, verified empty-library Staging setup documented for
public base `c5508f3d717790c58f52e57c38b07d2faa0a26be`. If you do not have an
existing working library, stop at building; do not fabricate a workspace file
or substitute someone else's library. An empty-library bootstrap still needs
implementation or verification before instructions can be offered.

On an isolated branch, commit the changes to be tested. Set `source_library`
to the existing working library you intend to import, and `original_source`
to the original source root recorded in that library's Project folder grant.
Do not assume it is `~/Projects/silkwire`. Run from the committed repository
you intend to copy. Replace both placeholder values before running:

```sh
source_library="/absolute/path/to/existing/working-library"
original_source="/absolute/path/to/original/source-root"
swift Scripts/build.swift --staging
swift Scripts/seed-staging.swift --source-library "$source_library" --source-repo "$PWD" --original-source "$original_source"
swift Scripts/install.swift --staging
```

The default working library is
`~/Library/Application Support/Silkwire Native Development`. The import creates
`~/Library/Application Support/Silkwire Staging`; the install targets
`/Applications/Silkwire Staging.app`, with backups and receipts under
`/Applications/Silkwire Staging Backups`. A new source checkout does not isolate
runtime data. Staging computer control is enabled by default; review the
[computer-control policy](computer-control.md) before use.

The importer refuses an existing destination. It reads one consistent atomic
snapshot even while the working app remains open; subsequent working messages
do not automatically sync. Partial failures are retained for inspection, never
deleted or mistaken for a completed import. The import receipt records hashes,
counts, revision and new grant path, never conversation text or credentials.

## Acceptance

These are procedures for a separately authorized runtime check. They were not
run in the fresh-download build-only review; neither import, installation,
Staging launch, nor provider behavior was verified by that review.

```sh
swift Scripts/test.swift StagingTests StorageTests RoomTests NativeEveTransportTests
swift Tests/run-transports.swift
```

Installed-bundle diagnostics use a UUID `SILKWIRE_STAGING_CHECK` and data under
Staging/Diagnostics only. They connect fresh sessions, have each agent read an
unpredictable synthetic phrase through the private Project broker, capture the
mounted window, and save a check receipt. Reopen with the same UUID and
`SILKWIRE_STAGING_CHECK_REOPEN=1` to check transcript/draft/identity preservation
without sending again. These are programmatic native checks, not external UI
click-through. Never substitute the owner's library into a diagnostic.

## Upgrades and going back

Staging does not automatically merge, push, deploy or upgrade the working app.
An approved promotion must preserve the exact tested executable/resources;
environment/name/signature metadata changes are recorded separately, not a
silent rebuild. Staging's conversations, grants, test files and agent sessions
are never promoted into the working library. The environment is bundle
configuration so the same executable can serve either installed environment.

Before a stable upgrade, quit the working app normally and preserve a matched
app-and-data recovery point. If going back later, first retain newer working
data separately: restoring older compatible data must not silently erase later
conversations. The approved working-app promotion script and its recovery contract are
documented in [Trusted team work](trusted-staging.md). Restoring a recovery
point is an explicit operation, not an automatic rollback.
