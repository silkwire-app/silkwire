# Computer control in Silkwire Staging

Jason asked on 2026-10-29 for Eve, Claude and Codex to have full control of his Mac
in Staging, so they can build Silkwire without hitting sandbox walls. It is on by
default for every teammate in the installed **Silkwire Staging** app only.
Development, Preview and Verification builds never offer it. Tests inject a
synthetic screen.

## What agents can do

Agents send one `<<COMPUTER {JSON}>>` marker per reply, alongside the existing
`READ_PROJECT` and `WORK_PROJECT` markers. Silkwire validates the marker, applies the
ask-first list and the idle/takeover rules, performs the action and returns the
result to the same teammate. Every action is written to the audit log.

| Action | Example |
|---|---|
| screenshot | `{"action":"screenshot"}` or `{"action":"screenshot","app":"Safari","window":"Home"}`. The PNG is attached to the agent's next prompt, with its frame and pixels per point |
| click, doubleClick, rightClick | `{"action":"click","x":120,"y":44}` (global screen points) |
| drag | `{"action":"drag","from":[10,20],"to":[300,400]}` |
| scroll | `{"action":"scroll","x":500,"y":500,"dy":5}` (lines; positive scrolls down) |
| type | `{"action":"type","text":"hello"}` |
| key | `{"action":"key","keys":"cmd+shift+t"}` or `{"keys":["cmd+a","delete"]}` |
| open, focus | `{"action":"open","app":"Xcode"}`, `{"action":"open","url":"https://…"}`, `{"action":"focus","app":"Terminal","window":"build"}` |
| tree | `{"action":"tree","app":"Finder","depth":6}`: accessibility elements with frames |
| shell | `{"action":"shell","command":"swift Scripts/build.swift --staging","cwd":"~/Projects/silkwire","timeout":900}` |
| read, write | `{"action":"read","path":"/abs","startLine":1,"lineCount":200}`, `{"action":"write","path":"/abs","content":"…"}` |
| task | `{"action":"task","state":"start","title":"…"}`, then `progress`, `done` or `blocked` |
| wait | `{"action":"wait","seconds":2}` |

Every action may also carry `"reason"`, which Jason sees in approvals and the audit
log.

A reply is a computer request when it starts with `<<COMPUTER`, or when one of its
lines does. Replies that start with another protocol's marker, such as a
`WORK_PROJECT` edit of these source files, are not computer requests, and neither is
prose that quotes the marker mid-line. Unknown actions and fields, prose or fences
around the marker, second markers and out-of-range values are refused before
anything runs, and the agent gets a correction. Three malformed requests in a row
end the reply (`ComputerProtocolTests`, `ComputerRoomTests`).

### Backends

When `peekaboo` is installed (`/opt/homebrew/bin` or `/usr/local/bin`), it handles
screenshots, UI trees and app launch/focus. If it fails, Silkwire falls back to
ScreenCaptureKit, Accessibility and `open`. Pointer and keyboard input are
**always** posted by Silkwire with CGEvent and tagged. Silkwire can tell its own
tagged events apart from Jason's real input. It could not do that for Peekaboo's
synthetic events, which would look like takeovers.

Accessibility calls use a 0.5 s messaging timeout, so a hung app can't freeze the
banner's Stop or takeover detection. The built-in tree walk runs off the main thread
and stops after 8 s. Window titles for click targets come from Accessibility when
CoreGraphics withholds them, which it does without Screen Recording.

macOS permissions: Accessibility (input, UI tree) and Screen Recording (built-in
capture). Settings → Agents shows both with Request and Open Settings buttons.
Because Staging is ad-hoc signed, macOS ties these grants to each exact build; grant
them again after installing a new Staging build.

## Not fighting Jason

- Screen actions (screenshot, input, open, focus, tree) wait until Jason has been
  idle for the configured period (20 s by default), or until he presses **Let them
  drive**.
- Any real mouse or keyboard input pauses the driving agent immediately. A
  partially done action stops between events, and the agent is told how far it got.
  The agent resumes after the next idle period. Input is detected three ways:
  global and local event monitors that skip Silkwire's tagged events; the system
  HID idle counter compared against Silkwire's last synthetic event; and a 2-point
  jitter threshold for pointer movement.
- After Let them drive, a 1.5 s grace period lets Jason move his hand off the
  mouse.
- While an agent drives, a banner floats at the top of every Space: "Claude is
  driving · move the mouse to take over · Stop". A purple pointer labelled with the
  agent marks where it last moved the mouse. Both are excluded from the agents'
  screenshots.
- One teammate holds the wheel for its whole reply; others queue in request order.
  A holder that hasn't acted for two minutes yields to a waiting teammate.
- Stop on the banner releases the wheel, denies pending questions, stops the
  current turn (including running shell commands' process groups) and ends this
  conversation's tasks.

The rules live in `DriveArbiter` (pure state) and are covered by `DriveArbiterTests`.

## Unsandboxed shell and files

`shell` runs `/bin/zsh -l -c` as Jason's user, with his PATH, real network and full
filesystem access. The default working directory is `~/Projects`, and the default
timeout is 900 s (up to 3600). The agent gets the exit code plus a bounded head and
tail of the output; the full output is saved under `Computer Control/Shell
Output/`. Stop kills the command's process group. The existing private-workspace
lane (`WORK_PROJECT`, Builder) is unchanged and remains the place for review builds.

## Durable tasks

An agent starts a task before multi-step work. While the task is `running`:

- Silkwire continues the teammate after each reply ("Task continuation", from
  Silkwire, not Jason), so Jason no longer has to press Pass. Plain-English progress
  replies stay visible.
- Tasks are saved to `Computer Control/tasks.json`. After a restart or reconnection,
  a running task resumes when its conversation's team is ready, and the agent is
  told to re-check state first.
- The strip above the composer shows each task's teammate, title, state (working,
  driving, waiting to drive, paused, needs you), elapsed time, step count, last
  progress and a Stop button. Settings → Agents lists recent tasks too.
- A task ends when the agent marks it `done` or `blocked`, or when Jason presses
  Stop. A task's own Stop also stops its teammate's live reply when that teammate is
  replying in the open conversation. The composer's Stop and the banner's Stop end
  every task in the conversation.
- Automatic continuations stop at 60 per task, after which the task waits for Jason.
  Each message from Jason refreshes that budget. A blocked task resumes when its
  agent sends `progress`.
- A switched-off teammate's tasks are never continued; the teammate can still close
  them.
- A single reply can run at most 250 actions; the next round continues from there.

## Ask first

By default, agents ask Jason before:

1. Keychain or password-manager access. Covers `security find-…`, `op`, `bw`,
   `lpass` and `pass`; Keychain Access, Passwords, 1Password and Bitwarden; the
   `Library/Keychains`, `~/.ssh/id_*` and `~/.openclaw/workspace/secrets` paths.
2. Anything touching the stable Silkwire app or its library. Covers:
   - non-Staging `app.silkwire.*` bundles;
   - the installed apps, backups and recovery folders under `~/Applications`;
   - the `Silkwire Native Development` and `Silkwire Runtime` libraries;
   - `killall` or `pkill` of Silkwire, AppleScript quit, `open -a "Silkwire Dev"`;
   - running (not reading) `install.swift` without `--staging`, and `promote-working.swift`.

   Source folders and build output such as `output/release/Silkwire Dev.app` do not ask.
3. Sending email or messages. Covers input into Mail, Messages, Slack, Discord and
   similar apps; input into webmail or chat tabs; `mail` and `sendmail`; SMTP;
   messaging webhooks and APIs; AppleScript or JavaScript for Automation to Mail or
   Messages.
4. Purchases. Covers input into the App Store or checkout and payment pages;
   typing a card number (Luhn-checked); `mas purchase`; Stripe payment APIs.
5. Deleting files outside project folders. Covers `rm`, `rmdir`, `unlink`,
   `trash`, `shred`, `find -delete`, `git clean` (including `git -C <dir>`), `xargs
   rm`, moving to the Trash, and disk erasure. Relative paths resolve where the
   command runs (default `~/Projects`), following any `cd` inside the command.
   Unresolvable targets ask. `rsync --delete` always asks. Finder's Move to Trash
   key asks. Replacing an existing file outside project folders asks.

Commands are checked one simple command at a time, so words inside quoted text such
as commit messages don't trigger rules. That includes one level of `sh`, `bash` or
`zsh -c` payloads and `$(…)` substitutions.

Everything else proceeds. In Settings → Agents, Jason can turn rules off, add
custom rules (a title plus phrases matched against commands, apps, windows, paths,
URLs and typed text), and edit the project folders where deleting never asks
(default `~/Projects`, plus each Project's granted folders).

The approval appears both in the floating banner and above the composer, showing
the exact command or target, with **Allow once** and **Deny**. Denials tell the
agent not to retry another way. `AskFirstPolicyTests` covers the detectors.

Paths are symlink-resolved before the project-folder check, so a directory link
inside a project that points outside is not treated as inside.

These checks recognize common commands and apps; they are not a sandbox. A
deliberately obfuscated command could avoid a pattern. Examples: a script file
that deletes on its own, `python -c "import shutil…"`, or a base64-decoded
pipeline. The audit log is the backstop.

## Secrets

Recognized credential values are masked before anything reaches the model, the chat,
the saved shell log or the audit log: private keys, JWTs, `sk-`/`ghp_`/`github_pat_`/
`xox…`/`AKIA…`/`AIza…` tokens, `Bearer` headers, and `password`/`token`/`secret`/
`api_key`-style assignments. Reading a known credential file (Keychain, `~/.ssh/id_*`,
`~/.codex/auth.json`, `~/.config/{claude,gh,openclaw}/`, `~/.aws/credentials`,
`~/.netrc`, the OpenClaw secrets folder) also asks first, and its contents come back
masked and flagged `redacted`, so an agent must not write the file back from that
text. Masking is conservative pattern-matching, not a guarantee; the shell log and
audit stay on this Mac.

## GitHub and the server

Agents reach GitHub and Jason's Hostinger VPS through the unsandboxed `shell` lane,
using his existing sign-ins. Two things gate this, both in Settings → Agents →
Connections, and both start connected/available.

**GitHub** (Jason's `gh`/SSH sign-in):

- Clone, branch, commit, push to their own branch and open pull requests proceed.
- Merging into `main`/`master` (`gh pr merge`, or a push whose refspec targets
  main/master), force-pushing, and deleting branches (`git branch -D`,
  `git push --delete`, `git push origin :branch`) ask first. Deleting a repo or
  release asks too.
- Disconnecting GitHub refuses `push`/`pull`/`fetch`/`clone`/`gh`; local Git still
  works.

**Server** (Hostinger VPS):

- Silkwire generates a dedicated `silkwire-agents` ed25519 key, kept in the Staging
  library (`Computer Control/Keys/`), separate from Jason's personal keys so he can
  revoke it without losing his own access. Silkwire never touches the server:
  Settings shows the public key and the exact steps for Jason to add it to the
  server's `authorized_keys` himself, and a Disconnect that deletes Silkwire's copy.
- Agents use it with `ssh -i <key path> <user>@<host>`. Reading logs, status and
  files proceeds. If no dedicated key exists, `ssh`/`scp`/`rsync` to a server are
  refused, so agents never fall back to Jason's personal key.
- Deploys, service restarts (`systemctl`/`service`/`pm2`/`docker`/`nginx -s`/…),
  config changes under `/etc`, and database clients (`mysql`, `psql`, `pg_dump`,
  `redis-cli`, …) ask first, whether run locally, under `sudo -u`, or inside
  `ssh host "…"`. Force-pushes include the `+refspec` form, and the protected-GitHub
  and server checks look inside `ssh host "git …"` too.
- Disconnecting the server refuses `ssh`/`scp`/`rsync` to a remote host.

Passwords, keys and tokens are used but never shown: the secret scrubber masks them
in model-facing output, the saved shell log and the audit log, and the agent key's
own path reads back redacted. The private key is never displayed.

## Audit log

Every action is recorded in `Computer Control/Audit/<date>.jsonl`. Each entry has
its time, teammate, conversation, task, action, summary, reason, target app and
window, outcome and rule. Outcomes are done, approved, denied, interrupted, failed,
stopped or refused. Screen actions also save a screenshot in `Audit/Screens/`.
Shell, file and task actions record their command, path, exit code or note instead
of a screen capture, so Jason's screen isn't captured while he works. Settings →
Agents shows the latest entries, filtered by teammate, with each screenshot.

## Tests

```sh
swift Scripts/test.swift ComputerProtocolTests DriveArbiterTests AskFirstPolicyTests AgentConnectionsTests ComputerHostLaneTests ComputerRoomTests
```

`ComputerHostLaneTests` checks the shell lane against real local processes: exit
codes, timeouts, saved output, line-numbered file reads, and Retina screenshots
fitting the 2 MB bound. `ComputerRoomTests` runs the store, room and control
center end to end with synthetic teammates and a synthetic screen. It covers:

- screenshot round trip and audit;
- real host-shell commands;
- ask-first denial and approval;
- a switched-off teammate;
- durable-task continuation without Pass;
- takeover mid-typing and Let them drive;
- one driver at a time on the open floor;
- banner Stop killing a running command;
- task resume after a restart;
- the independent review's regressions: inline marker mentions, corrections,
  per-task Stop, switched-off teammates, and the continuation budget.

No real pointer, keyboard or screen is used in tests. Real-device checks of
permissions, event tagging and the overlay need the installed Staging app (see the
delivery notes).

## Combined candidate review safeguards

Captures and UI trees that span real human input are discarded, even if Jason
invites the agents again before capture finishes. Keyboard input cancels an
invitation immediately; only hand-off mouse motion has a short grace period.
Double-click checks ownership before each click. Drag approvals consider both
endpoints, and direct deletion/replacement checks resolve existing symlink ancestors.
These are checks for common actions, not confinement of arbitrary host shell code.

A task checkpoint must save before Silkwire acknowledges durable success or sends
an automatic continuation. Save failures pause running work in memory and show
a warning; Stop still stops immediately even when its disk checkpoint fails.
If a stop cannot save, the warning means the older disk state may remain. Audit
write failures appear in the action result and Settings. Shell audit entries keep
the complete command, exit code and saved output reference, with recognized
credentials redacted. Known provider credential paths ask first; file reads from
known credential stores are withheld. Recognized credential fields and token
formats are filtered from model-facing reads, shell output and saved shell logs.
Redacted results are explicitly incomplete and must not be used to reconstruct or
overwrite a file. This filtering does not recognize every possible private value.

Private candidate tests use the same COMPUTER parser with an owned-window AppKit
backend and simulated teammates. They cannot enable this global desktop/host
shell lane. Rollback preserves the newest computer-control audit/settings/task
history and blocks running tasks until Jason reviews and resumes them; it does
not replay historical running tasks from an older conversation snapshot.
