# Independent candidate review — 2026-10-24

Input: `919a9466b0ffc4ea753ef034949793512cc446d3`, imported by fetching the
teammate bundle into a standalone clone of the combined candidate bundle. Review
branch: `review/independent-20261024`. No shared checkout, app installation,
publication, library import, promotion or live provider session is used.

## Review corrections

- Ari now uses the same latest-attempt key as the host: a named check's name,
  otherwise its command. Previously, two named checks using one command could
  turn a failed check into “Ready for review.” Retries may change their command.
- A successful wrapper containing `$(` or backticks is unconfirmed. Bash DEBUG
  misses the last exit in `echo "$(false)"`; an intact empty record is insufficient.
  This deliberately includes literal occurrences. Use independent named checks.
- Staging identity refuses a non-executable main executable and includes file
  permissions in its reviewed manifest. Code-signature verification alone accepts
  the executable after its execute bits are removed.
- Finished-workspace provenance requires the actual current Git head to equal the
  receipt head, in addition to matching clean files and source digest.
- Unknown process-list status refuses install/recovery. Recovery requires a valid
  signature before and after copying. Rollback messages distinguish an actual
  restoration, no previous installation, and a failed automatic restoration.
- `Scripts/build-staging-installer.swift` builds an operator-only command using
  exactly the app's installer class. The installed working app predates the new
  install sheet, so the first upgrade needs this bootstrap or another reviewed
  external install step. It has no library/seed/promotion/provider operations.

## Evidence and acceptance limits

The standalone delivery's REVIEW.md and evidence directory record actual commands,
exits, final revision and hashes. Supplied logs are evidence from the supplier,
not independent reruns. Their green results were inspected alongside the diffs.

The review session denies nested command sandboxes, process inspection, some
bookmark/pasteboard services and loopback/WebKit services. The supported compiler
setting `SILKWIRE_COMMAND_SANDBOX=1` disables only the compiler's redundant macro
sandbox; no protected command fallback was added. Tests requiring unavailable
services remain failures/unverified. A direct offline web probe failed compiling
WebKit's content rules, before rendering.

`ShellEvidenceReviewTests` executes the real Bash wrapper/classifier with harmless
commands, without claiming workspace sandbox coverage. `StagingInstallerReviewTests`
uses signed temporary bundles and injected process-list results; it exercises copy,
backup, restore, forced receipt-write failure and rollback without using real
Applications. The original installer suite's actual process inspection remains
separate. BuildReviewTests uses fixture providers to read exact shared artifacts.

The full real workflow (inspect → edit → protected build/test → another live
teammate's review → candidate for Jason) still needs an unrestricted app session.
Mounted tables, side composer/divider persistence, Ari Stop, jump without following,
install sheet and transcript previews require visual interaction checks. Real
installation/recovery and provider-live/saved-session checks were not performed.

The web inspector's GET-only claim needs stronger acceptance: its page-world JS
patches cover ordinary forms/fetch/XHR/beacons/WebSocket. Follow-up: worker
contexts never receive those patches, so dedicated, module, blob, data, shared and
service workers are now refused before they start, in every frame realm.
`WebInspectionWorkerTests` reproduced worker POSTs reaching a loopback site on the
reviewed revision and proves none (and no worker script fetch) after the fix. These
remain page-world patches, not an immutable host request boundary; WebKit offers no
public per-method request filter. Offline preview has separate blocking content rules.

The per-step file is writable within the command sandbox. Deletion is detected;
truncation or disabling traps is not tamper-proof. A script's own exit is not proof
that every internal assertion ran. Review exact commands, output, coverage and exits.
Model/effort switching and Anthropic usage production remain absent.

## Operator installation after acceptance

Build the committed Staging app and helper; review its identity before installing:

```sh
swift Scripts/build.swift --staging
swift Scripts/build-staging-installer.swift
output/installer/silkwire-staging-installer review 'output/staging/Silkwire Staging.app'
```

Quit Staging normally. Run `install APP EXPECTED_MANIFEST` with the exact full
manifest returned by review. The helper rechecks the candidate, keeps the old app,
copies and verifies the new app, and saves an install receipt under
`~/Applications/Silkwire Staging Backups/Install Receipts`. This replaces only
`~/Applications/Silkwire Staging.app`. Do not seed an existing Staging library,
promote into the working app, or restore older conversation data.

For recovery, quit Staging, use `backups`, then `review BACKUP_APP`, then
`restore BACKUP_APP EXPECTED_MANIFEST`. Both the backup and replaced app are kept.
If automatic restoration reports failure, inspect the reported retained paths;
do not infer that an older app was put back.
