# Final Staging candidate after d990610

All operator entry points use /Applications/Silkwire Staging.app: one-click installer,
in-app deferred helper, legacy Scripts/install.swift --staging, rollback and reopen.
Backups and receipts use /Applications/Silkwire Staging Backups; the current user's
Staging library stays at ~/Library/Application Support/Silkwire Staging. Old copies
and backups in ~/Applications are retained without migration or modification.
Fixture-injected installation directories continue to select synthetic libraries.

The new GitHubVpsPolicyTests is imported from Claude d57c5b6 (bundle SHA-256
70c69ee5fd319c1bf3b84b476902a0620d1740c8812754e5661a6eca502915b0).
Only that additive suite is imported; d990610's merged feature and reviewed controls
remain. This is not a replacement with Claude's rebased source tree.

The sandbox failure is ssh-keygen's OS account lookup, not a policy failure.
A private HOME/USER still produces 'No user exists for uid 501' when the libinfo
Mach service is denied. The test now injects a test-only CryptoKit Ed25519 generator,
encoding a fresh OpenSSH fixture key; no existing key or OS user lookup is needed.
The production ComputerControlCenter default still uses AgentConnections.create
and ssh-keygen. AgentConnectionsTests separately covers real key generation,
permissions and deletion on the host. Policy command probes run with fixture cwd.
A failed fixture setup reports an error instead of force-unwrapping a missing key.

The 42 policy checks are unchanged. Rerun the suite on the host and through
sandbox-exec with libinfo Mach lookup and network denied; retain the exact profile,
exit and complete 42-check output before claiming the fix. The optional
SILKWIRE_POLICY_EXPECT_SANDBOX assertion verifies the kernel boundary without adding
a policy check. Live GitHub/VPS activity and provider connections are not required.

The receipt must enumerate every suite and known failures. Claude reported four
pre-existing exit-133 cases: NativeInstalledSmokeTests, NativeSavedConnectionTests,
SideBySideReaderTests and SourceArchiveRoundTripTests. The source archive test is
configurable and already passed on d990610 with SILKWIRE_CANDIDATE_APP set; do not
report it as still failing without checking. Smoke and saved-session diagnostics
remain unconfigured so they fail before opening an owner app/provider. SideBySide
must be reported with its actual assertion, not assumed to be an environment issue.
NativeInstalledConnectionTests is a live-provider test despite its filename; list
it as not run along with the explicitly named Live suites. Synthetic private UI
checks cover launch/reopen behavior without owner sign-ins.
