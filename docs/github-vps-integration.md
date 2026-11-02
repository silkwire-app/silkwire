# GitHub/VPS integration decisions

Inputs: the working combined app source 39395120b7645438ac39f2ea9c6d480c17205be1,
its installer fixes through 3e2b62f08cf313ec64bb421ab95e9b5685eff4e1, and Claude Code
claude-code/github-vps fa14d86e787db4718b352d8b55d122a071c34daa. The latter full-history
bundle has SHA-256 8aa155e372213a318a89f0cf2182064fb1392fc9113ae9995e0ab4a896896207.

The five conflicts listed in the prior INTEGRATION-FINDINGS.md are resolved as follows:

| File | Decision |
| --- | --- |
| AskFirstPolicy.swift | Keep our fail-closed realpath ancestor and symlink handling. Add all GitHub/VPS rules, disconnect detection, remote command parsing and credential paths from Claude. |
| ComputerControlCenter.swift | Keep generation-based capture discard, checks at both drag endpoints, checkpoint failures blocking all running work, structured audit evidence and warnings. Keep all connection UI/backend state and capability notes. |
| ComputerDriver.swift | Keep our continuation check before every click, credential-store withholding (including resolved paths), output-save warning and redaction flag. Extend our redactor with Claude's additional patterns. |
| DriveArbiter.swift | Keep our equivalent mouse-motion-only grace expression. |
| DriveArbiterTests.swift | Keep our check and all additional tests from Claude. |

## Seven overlapping findings

1. Capture: keep our generation check, which also rejects input followed by reinvitation, both direct and automatic capture.
2. Invitation/double click: keep our keyboard/click takeover and each-click checks.
3. Task persistence: keep our failure handling for existing running tasks and Stop. Adopt Claude's removal of an unsaved newly-started task: our blocked phantom start otherwise prevented retry after storage repair. Test both refusal and repaired-storage retry.
4. Audit: keep our structured command, fullOutput, exitCode and persistenceWarning plus result auditWarning. Add Claude's audit-target scrubbing and explicit in-memory NOT SAVED TO AUDIT LOG label. The target/title redaction is an additional case our original record scrub did not cover.
5. Credentials: keep our whole-store withholding and symlink checks; add Claude's .config/claude, .config/gh, .config/openclaw paths and dedicated Computer Control/Keys path. Add rk-/pk-, github_pat_, Slack xox*, AWS AKIA*, Google AIza* formats and additional passwd/secret/token assignment fields. Existing sk-/gh*/JWT/Bearer/private-key cases remain covered. Approval display is scrubbed before clipping.
6. Deletion: keep our deepest-existing-ancestor realpath resolution, including dangling/error fail-closed handling.
7. Drag: keep our separate evaluation of both endpoints and rule approval tracking.

These are conservative host policy and recognized-secret detectors, not a proof of
arbitrary shell behavior or a universal secret detector.

## Claude's six GitHub/VPS review fixes retained

- Dedicated identity argument can be passed to ssh without treating key use as reading the key; actual reads remain credential access.
- sudo -u postgres psql resolves to the database tool.
- Server command refusal without a dedicated key; Disconnect key deletion and connection refusal.
- +refspec force pushes ask for every branch.
- docker/docker-compose/systemctl action detection past value flags.
- Protected GitHub checks inspect ssh remote payloads.

The imported AgentConnectionsTests, AskFirstPolicyTests and ComputerRoomTests retain
these regressions. The original feature includes Settings controls, separate agent
key generation/setup instructions, GitHub protected operations, server operations,
connection refusal and capability notes. No server authorization is performed here.

## Recovery

Full install backups retain Computer Control/Keys and settings.json together. Rollback
copies the entire newest Computer Control directory, preserving disabledConnections
and the presence, rotation or absence of keys from the same point in time. Running
tasks are blocked and both raw histories retained. StagingLibraryRecoveryTests uses
synthetic key bytes to check install/backup, mode 0600, rotated-key rollback, retained
Disconnect settings and no deleted-key resurrection. No owner key is read by tests.

The installer also retains bounded-memory hashes, its responsive status window,
quit timeout/cancel and exact-manifest already-installed no-op. The new package uses
a v4 launcher identity to distinguish it from earlier installers.
