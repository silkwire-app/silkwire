# Staging install in the exclusive lane

Status: delivered on `claude-code/installer-exclusive`, based on outside Codex's
practical-release head `8caa50c`. Workload-proof recovery added on
`claude-code/installer-recovery` (from combined candidate `3caa3e1`). Nothing has been
installed, pushed, merged or deployed.

Installing a new Staging build, or rolling back to an earlier one, is machine-wide work.
It replaces `/Applications/Silkwire Staging.app` and swaps the Staging library, so it runs
only in the **exclusive lane** of `HostExecutionCoordinator` (`admitExclusive`). The lane
uses the app-global ownership registry, the same one every room, trusted workspace,
Builder and background job uses.

## What the lane guarantees

- **It waits; it never stops running work.** The install queues durably, then waits until
  no record holds resources. That covers private workspace jobs, background jobs and
  previews in every Silkwire process that shares the registry, including uncertain
  records (finished work whose exit isn't proved). The install doesn't Stop, kill or
  orphan any of them. While it waits, the caller sees plain status. Running jobs are
  counted, and unproved ones point to Release on their job cards. Cancel withdraws the
  request, and nothing changes.
- **New work waits while the install runs.** From the moment the install queues, new
  private admissions are held back (`exclusivePending`). While it holds the lane they
  are held back too (`exclusiveHeld`). A begin with `wait: false` is refused with the
  existing plain text, and a waiting admission starts only after the lane is finished.
- **The installer is always joined.** Once admitted, the installer call runs on a
  host-joined task that is always awaited, even if the caller cancels. The lane is
  finished only after that call returns, whether it succeeded or failed. A failed install
  still releases the lane.
- **Strict exit proof, not practical cleanup.** Inside the lane, the installer launches
  no child process:
  - The signature check is in process. `SecStaticCodeCheckValidityWithErrors` uses
    nested-code and strict flags plus the code's own designated requirement, matching
    `codesign --verify --deep --strict`.
  - The "is Staging open" probe is in process (libproc `proc_listallpids` and
    `proc_pidpath`).
  - Every remaining launch site (`sourceDigest`'s git, `relaunchAfterExit`) refuses while
    `StagingInstallScope.exclusiveOperation` is set.

  That is the design. The proof is the kernel workload scan below, run when the joined
  call returns and again by every recovery: the lane is released (`.verified`) only
  when it shows the install's whole workload has ended. Anything still running finishes
  the lane `.unconfirmed` and keeps it held, naming the processes, until a later check
  proves them gone. `.privateCleanup` can't release an exclusive record; the
  coordinator already refuses it. The helper and Try This Build also watch themselves
  with kernel `NOTE_FORK` and name any fork in the evidence.

## Whole-workload proof (`StagingInstallWorkload`)

Every identity in the proof is a stable kernel identity, never a bare PID: a process's
kernel unique ID (64-bit, allocated in increasing order at fork, kept across exec, never
reused), its PID version (a global counter that advances at every fork and exec), or an
audit token (PID plus PID version, one exact program image). PIDs are shown to people
only next to the unique ID, because that is how processes are looked up.

Before admission, the journal (version 3) records the installer's kernel lineage: its
kernel unique ID and PID version, the unique ID of the process macOS holds responsible
for it, and two watermarks: the kernel's unique-ID and PID-version counters at that
moment. The counters are read from a probe process (`CounterProbe`: `/usr/bin/true`
spawned suspended, with no environment, so it never runs an instruction; read, then
SIGKILLed and reaped). Every process created afterwards has higher values. Both
watermarks are refined once the lane is admitted, still before any installer code runs.
The held registry record carries its owner's unique ID too (`ownerUnique`), and recovery
matches record and journal by it. While the installer runs, the process
environment carries `SILKWIRE_STAGING_INSTALL=<operation>`, so anything started inherits
that tag.

What the kernel keeps, verified on this Mac (macOS 27):

- A process's parent unique ID is set when it is created. It survives the parent's exit
  and reparenting to launchd, until the process next execs. Then it becomes launchd's,
  but the original parent's PID version is still kept.
- Unique IDs and PID versions come from global counters that only increase. PIDs don't
  (they are reused).
- Responsibility is inherited at spawn and survives reparenting.
  `responsibility_get_uniqueid_responsible_for_pid` returns the responsible process's
  unique ID (UINT64_MAX on error). It survives that process's exec. Once the responsible
  process exits, the kernel answers with the process itself, so no other process can
  ever be named as its owner.
- `proc_listallpids` copies the kernel's process list in one walk under the kernel's
  process-list lock (xnu `proc_listpids`): newest first, then launchd (1), the kernel
  task (0), then zombies. A process still inside fork has its unique ID but is not yet
  on the list; its parent is on the list and alive (it is inside fork).
- `PROC_PIDUNIQIDENTIFIERINFO` (unique ID, parent unique ID, PID version, original
  parent's PID version) and `PROC_PIDT_SHORTBSDINFO` (owner, name) are readable for
  every user's processes. `PROC_PIDT_BSDINFOWITHUNIQID` is not (EPERM for other users).
- macOS hides the environment of Apple platform binaries (such as /bin/sleep or /bin/sh)
  from other processes. `KERN_PROCARGS2` returns only their path and arguments.

A live process started after the install began counts as the install's workload if:
1. its parent chain reaches the installer, by unique ID or, after a reparent and exec,
   by PID version; or
2. the chain reaches a parent that started after the install began and has exited. The
   only exception is a process the kernel attributes, by unique ID, to another live app
   that was already running when the install began, is unrelated to the installer and
   isn't tagged, such as a browser's crash handler. Both ends are re-checked against the
   cut's identities afterwards, and the attribution must be unchanged; or
3. it is this user's process, its environment is visible, and it carries the tag.

The installer process itself counts too while its unique ID is alive, even after an
exec has changed its audit token.

The same scanner serves private-job cleanup (docs/practical-release.md). A private
job's scope names its suspended launch identities and observed descendants as
`roots` instead of the shared app process, and uses its own environment key. A root
still alive is a survivor. An orphan that only may be the job's is a survivor that is
not `signalSafe`: it keeps ownership held but can't authorize a kill unless the job's
tag matches. Private cleanup and its lineage sampling call the scanner as `pass`, which
is one consistent cut (with its own counter probe).

"Ended" is proved on a **consistent cut** of the whole process table, not on snapshots
that something could slip between. One cut (`StagingInstallWorkload.cut`):

1. Starts a counter probe, then takes one atomic kernel listing at once.
2. Requires the listing to reach the kernel task (PID 0) with launchd before it, and to
   include the probe. Otherwise it was cut short and proves nothing.
3. Reads every listed process (except the probe and zombies) back by its PID. Each must
   still be alive **and** be the process that was listed: its unique ID must be below the
   probe's. A higher one means the PID was recycled by a newer process. If any listed
   process exited before it was read, or can't be read, the cut is incomplete.
4. Classifies every process by the rules above. Reads made through a PID (environment,
   owner, name, responsible process) count only if the same PID still names the same
   unique ID afterwards.

Why this closes the gap between scans: a complete cut sees every process that existed
at the listing's instant, with its lineage, and a process being forked at that instant
has a listed, live parent. If no process is install work at that instant, then no install
work existed then. Afterwards, new install work could only be started by a process that
existed then, and the cut classified it. So the proof doesn't depend on observing the
time between scans, or on how fast anything forks. A workload that keeps handing itself
off either shows up as a live link (named), or makes the cut incomplete because a listed
process exited before it was read. Either way the lane stays held.

Two consecutive complete cuts with no install work are required, within 3 s. A cut with a
live survivor ends the check at once (held, with names). Incomplete cuts are retried
every 20 ms; if no two consecutive complete ones happen in time, the result is
unprovable and the lane stays held. The scan runs on its own thread with a hard limit
(3 s + 5 s): a kernel read that blocks makes the result unprovable; it can never hang
recovery or the lane. The evidence string names the watermarks and the number of
processes whose environment macOS hid.

## Entry points

| Entry point | How it uses the lane |
|---|---|
| Install sheet in the working app (`StagingInstallView.install` / `.recover`) | Runs `installer.install` / `.recover` in process through `StagingInstallLane.application.run`. |
| Staging updating itself (`handOff`) | Staging can't replace itself while it's open. It launches the helper with `--exclusive-operation <UUID>`, and the helper takes the lane under that UUID. Staging keeps running, and so does its work, until the registry shows the helper **holding** that lane. Only then does Staging save and quit, and the helper installs after it exits. Cancel terminates the waiting helper, which withdraws. A helper from an older build doesn't understand the flag and exits with usage (2). Staging then reports that the build can't update safely and installs nothing. |
| Helper CLI (`install` / `restore`, and `Scripts/install.swift --staging`) | Takes the lane on the app's registry. Ctrl-C while waiting withdraws. |
| Helper legacy `after-exit-*` (4 arguments, from an older Staging) | Takes the lane, but bounds the wait to 300 s and then refuses. The older app has already quit by then, so its records can only be recovered at its next launch. |
| Try This Build (`Tools/TryThisBuildMain.swift`) | Takes the lane **before** asking Staging to quit, so a quit request never ends running work. Quitting Try This Build while it holds the lane waits for the cancelled worker to return first. |

The helper and Try This Build now compile `StagingInstallLane.swift`,
`HostExecutionCoordinator.swift`, `PhysicalWorkOwnership.swift`,
`HostLocalExecutionEvidence.swift` and `HostPrivateExecutionCleanup.swift` alongside
`StagingInstaller.swift`. This is set in `Scripts/build.swift`,
`Scripts/build-staging-installer.swift` and `Scripts/package-candidate.swift`.

## Restart mid-install

Before admission, the lane writes a journal, `staging-install-<operation>.json` (0600, in
the 0700 registry directory). It holds the operation and the exact installer process's
audit token (PID plus PID generation). If the installer process dies while it holds the
lane:

1. The record stays held (`executing`, owned by the dead PID). New work keeps waiting, so
   nothing can race a half-finished install.
2. `StagingInstallLane.recoverInterrupted()` runs at app launch, when the install sheet
   opens, before every lane run, and every 2 s while an install waits behind a held
   lane. After a launch, sheet open or unproved finish that leaves a lane held, it
   re-checks every 2 s for up to 30 minutes. It releases the record with
   `reconcileAfterPhysicalExit` only when all of these hold:
   - the journal matches the held exclusive record by the installer's kernel unique ID
     and carries version-3 lineage;
   - the exact installer process is gone (ESRCH, or the same PID with a different
     generation), and no process with its unique ID is alive (an exec changes the
     generation, not the unique ID). A host that lives on, like the working app, qualifies only after its
     installer call returned and it finished the lane as unproved;
   - the workload scan proves the whole workload ended.

   Each of these keeps the lane held, and the reason appears on the install sheet and in
   a waiting install's status:
   - a live or uninspectable installer;
   - a missing, unreadable or lineage-less journal (evidence lost, or written by an
     older build), including a version-2 journal, which named the responsible process
     only by PID;
   - a held record with no owner unique ID (written by an older build);
   - any surviving descendant, possible orphan or tagged process, named by kernel
     unique ID (and its PID);
   - an inspection that can't complete.
3. Files: the installer records an in-progress marker,
   `Silkwire Staging Backups/.operation-in-progress.json`. Every path in it is saved
   *before* the move it describes: the retained previous app, the later library, and the
   planned receipt. The next install or rollback runs under both installer locks and
   inside the lane. It first undoes an uncommitted operation:
   - The previous app (and, for a rollback, the library) is put back.
   - Partial copies are retained as `incomplete`, never deleted.
   - If the receipt already exists, the operation committed and nothing is undone.

   The install sheet shows when such a repair is pending.

## Tests

`Tests/StagingInstallExclusiveTests.swift` uses a private registry, Applications folder
and library, never the real ones.
- Install blocked while a background job and a preview/build hold ownership, including
  after one becomes uncertain. Neither is stopped. The install proceeds after the last
  one releases, and Cancel while waiting withdraws.
- New work waits during the install: an immediate begin is refused, and a waiting begin
  starts only after the lane finishes.
- A failed install (bytes corrupted after the copy) rolls back and releases the lane. So
  does a refused install.
- A child launch inside the lane is refused. An observed fork whose child has exited is
  released only with the scan's proof. A child still running when the installer returns
  keeps the lane held, by name, until it exits, and then the lane frees itself.
- Crash before the installer could record a child (real processes, SIGKILL):
  - (a) The installer starts a child. Held while the child lives.
  - (b) The child starts a grandchild and exits, and the grandchild execs afterwards, so
    only the PID version links it back. Held while the grandchild lives.
  - (b2) The same, but the grandchild execs before its parent exits. Held.
  - (d) The installer execs into another program. Held while it runs.
  - (c) After everything exits, each lane is released with the scan's proof. It stays
    held if inspection fails, if a tagged process lives, if the lineage was lost, or if
    the journal was lost.
- The test re-runs itself as its own responsible process, as the working app is, so
  orphans left by other suites running at the same time are attributed elsewhere.
- Restart: a real child process (the same test executable) takes the lane and moves the
  previous app aside, then gets SIGKILL. The lane is not released while the child lives,
  and it still blocks work after the kill. Recovery then releases it. The next install
  repairs the files (previous app put back, partial copy retained) and installs.
- The in-process signature check agrees with `codesign --verify --deep --strict` on
  valid, tampered, added-file and unsigned bundles.

`Tests/StagingInstallLineageTests.swift` (real processes, private registry; fixture
`Tests/Fixtures/InstallWorkloadFixture.c`, compiled by the test):
- A. Spawn during the scan. A crashed installer's workload is a chain that forks its
  successor and exits at once (no process of it outlives one fork), started without the
  tag. For 8 s of recovery checks the lane is never released, and new work waits; a
  chain paced at 30 ms per hand-off is named as the install's orphan. Once the chain
  stops, the lane is released with the cut proof.
- B. PID reuse. The installer (SIGKILLed) and an app-like owner whose helper is a
  post-start orphan are both gone, and their **exact PIDs are recycled** by the fixture
  (it forks until a new process holds each one). While the owner lived, its orphan was
  attributed to it by unique ID and not counted. After the reuse, recovery keeps the
  lane held for the orphan, names it by unique ID, and takes neither PID holder for the
  installer or the owner. A version-2 journal keeps the lane held. Once the orphan and
  the PID holders exit, the lane is released with evidence naming the installer by
  unique ID.

`Tests/InstallerResponsivenessTests.swift` (compiled with `-D INSTALLER_UI_TESTING`
together with the Tools file and the lane sources) checks that the shipping launcher uses
the app's registry, and that a UI install leaves exactly one finished exclusive record.

## Limits

- The lane covers Silkwire processes that share the app-global registry. Work outside the
  registry, such as a provider chat turn or computer control, isn't registry work (see
  safe-parallel-ownership.md), so the install neither waits for it nor blocks it.
- The in-app path doesn't watch itself for forks, because the working app runs other
  subprocesses concurrently. The scan covers it either way. Any app subprocess started
  during the install and still running when the installer returns (for example a
  provider turn) keeps the lane held until it exits, because nothing tells it apart from
  install work.
- These are conservative holds, not proof gaps. An orphan started after the install
  began whose parent has exited, and which the kernel attributes to the installer's
  responsible app or to no live app, keeps the lane held. Examples: a daemon launched
  from the same Terminal as the helper, or a system daemon that double-forks. The reason
  names it.
- What the proof can't see:
  - Work handed to a process that already existed and is not install work, such as
    launchd or an XPC service: the new process's parent is that process, and the
    install's environment isn't inherited. Kernel lineage can't follow a request made
    over IPC. The installer starts no such work by design.
  - Tags on Apple platform binaries, whose environment macOS hides. Lineage still covers
    those processes.
- Apps started after the install began don't excuse orphans: such an app can't vouch
  for a post-start orphan, which then keeps the lane held until it exits.
- Closed in this revision: a lineage that forks and exits faster than a scan (the cut
  proof above), and every PID-based attribution (the responsible process, the record's
  owner, survivor names and the update helper's wait for Staging to quit are all by
  kernel unique ID or audit token).
- A cut needs every listed process to be read back alive. On a machine that is creating
  and ending processes very quickly, cuts can be incomplete for a while; the lane then
  stays held and is re-checked every 2 s.
- An install whose host died is released at the next Silkwire launch, sheet open or
  install attempt (then re-checked every 2 s while held). Until then, new work waits.
