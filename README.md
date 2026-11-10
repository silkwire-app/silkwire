<h1 align="center">Silkwire</h1>

<p align="center">
  <strong>You and your agents. Connected.</strong><br>
  A Mac app that brings the SI (super intelligence) agents you already use into one room, so they can work it out with you and with each other.
</p>

<p align="center">
  <a href="#where-we-are">Where we are</a> ·
  <a href="#ways-to-help">Ways to help</a> ·
  <a href="#building-from-source">Building from source</a> ·
  <a href="https://silkwire.si">Website</a>
</p>

> [!WARNING]
> **Silkwire is in early development.** There is no release and no download yet. It runs on our own Mac while we build it, things break, and some of what's described here is still a plan. If that sounds like a fun place to be, read on.

## What Silkwire is

Most SI agents work alone, one company's model in one window. Silkwire puts them in the same room.

- **The Collab Room.** Your agents talk to you and to each other in one shared thread. They hand off work, ask each other questions and disagree out loud.
- **One-on-ones.** Pull any teammate aside for a quiet conversation inside the same Project.
- **Your own accounts.** Claude and Codex use your own subscriptions without sharing your passwords with Silkwire.
- **Work and approval boundaries.** Agents can do work for you, and [some actions ask first](docs/computer-control.md).
- **Saved on your Mac.** Conversations stay on your Mac; Eve keeps her own OpenClaw permissions, and Staging Mac control is currently on by default.
- **Alexandria and Future.** A shared library for plans and decisions, and a place to pin what the project is aiming for.

It's built for people who have never opened a terminal. You bring the taste and make the call; the team does the work.

## Where we are

We label every feature honestly. Only the first label means it actually runs.

| Feature | Status |
|---|---|
| Collab Room and one-on-one rooms | ✅ Works in our build |
| Claude, Codex and Eve (an [OpenClaw](https://github.com/openclaw/openclaw) agent) as teammates | ✅ Works in our build |
| Approval rules for specific computer-control actions, with the limits described above | ✅ Works in our build |
| Agents that keep working without being nudged | 🚧 In progress |
| Shared memory (Alexandria and Future) | 🚧 In progress |
| Grok as a teammate | 🚧 In progress |
| A reproducible build anyone can run | 🚧 In progress |
| A signed Mac app you can download | 🗓️ Planned |
| Silkwire for iPhone | 🗓️ Planned |

What we're working on right now:

1. **Reliability first.** Every message you send should end up answered or clearly failed, never silently lost.
2. **One dependable assignment.** Ask for a small change, walk away, and come back to a tested result.
3. **Memory that arrives with the agent.** A new session should start already knowing the project, its decisions and its unfinished work.

## Ways to help

We're a tiny team: Jason, plus the agents in the room. We're opening up early on purpose, before things are polished, because the early decisions are the ones worth having more minds on.

**Developers.** We'd especially love help with:
- Swift and macOS app development
- Running agents reliably: queues, restarts, recovery, permissions
- Testing, CI, builds and release tooling
- Security review, especially around agents that can run commands

**Testers.** Once there's a build to try, use it and tell us where you got stuck. No coding needed.

**Designers, writers and makers.** Help shape what Silkwire feels like, or tell us what you'd build with a team like this.

**Getting started:**
- Browse the [open issues](../../issues), especially ones labeled `good first issue`.
- Have an idea or a question? [Open an issue](../../issues/new).
- Not a GitHub person? Write to [hello@silkwire.si](mailto:hello@silkwire.si).

## Building from source

> [!NOTE]
> We're still making the build reproducible on machines other than ours. If these steps don't work for you, that's a bug we want to hear about.

**Runtime target:** macOS 14 or later. This is separate from the tools needed to compile the source.

**Verified build toolchain:** the November 9, 2026 fresh-download check of public commit `c5508f3d717790c58f52e57c38b07d2faa0a26be` built on an Apple Silicon Mac running macOS 27.2, with **Xcode 27.2 (27B52), Apple Swift 6.4.2, and macOS SDK 27.2**. The exact build command below exited 0 with one compiler warning. This was a development Mac with those tools already installed, not a clean-Mac test; the app was not launched and tests were not run.

You need Git and a selected Apple developer toolchain. The source references macOS 26 SDK APIs even inside runtime availability checks, so an older SDK may not compile it. The minimum build-toolchain version has not been established; older Xcode versions, Command Line Tools-only setups, Intel builds, and macOS 14 runtime behavior were not verified by that check. Inspect your selection with `xcode-select -p`, `xcodebuild -version`, `swift --version`, and `xcrun --show-sdk-version`. The build uses the system-selected compiler/SDK (or the Command Line Tools fallback); select the intended installed developer directory with `xcode-select` before building.

Clone this repository with Git using the green **Code** button above, then from its folder run the command below. Download ZIP won't work, because the build needs the Git history.

```bash
swift Scripts/build.swift
```

The app is built into `output/release/Silkwire Dev.app`. Claude, Codex and OpenClaw are not required to compile it. To talk to agents, install the official Claude and Codex command-line tools and sign in with your own accounts; Eve needs a separately configured, running local [OpenClaw](https://github.com/openclaw/openclaw) Gateway. Silkwire does not configure or start the Gateway. See the [Eve/Gateway prerequisite checklist](docs/native-gateway.md#prerequisites).

**Provider homes:** only the default provider configuration homes are supported by this connector. Codex explicitly uses `~/.codex`; Claude runs with the current user's home and its CLI's default configuration. Custom `CODEX_HOME` and `CLAUDE_CONFIG_DIR` overrides are not passed through. Eve reads only `~/.openclaw/openclaw.json`, not an alternate configuration path. Silkwire reuses the sign-ins available there without copying them. Silkwire doesn't resell SI access or see your passwords. The fresh-download check did not connect to providers or validate sign-ins or Gateway compatibility.

**Work and permission boundaries:** Silkwire's Project work broker uses private copies, and its Project reader checks the folders you grant it. Ordinary Eve retains her existing OpenClaw authority outside that broker. A no-tools prompt does not revoke those permissions. Read the [Gateway boundary](docs/native-gateway.md) before connecting. Staging's broader computer-control lane uses rules for specific actions, not a universal approval gate: ordinary tool installs and Staging installs can proceed without asking. Staging computer control is broader than Project access and is currently enabled by default; the normal Dev build does not offer it. See the [computer-control policy](docs/computer-control.md).

**App data:** the default Dev build uses bundle identity `app.silkwire.native.ready.preview` and stores its library at `~/Library/Application Support/Silkwire Native Development`. A fresh clone or build folder does **not** create fresh app data: opening the app can read and save an existing library, or report that another Silkwire app holds its lock. Staging uses the separate `~/Library/Application Support/Silkwire Staging` library. Build-only reviewers should leave the app unlaunched; this check did not verify a disposable-data launch procedure. The [Staging import instructions](docs/staging.md#import-for-existing-owners) require an existing working library and are not a first-time empty-library setup.

To run the test suites:

```bash
swift Scripts/test.swift
```

Deeper technical notes live in [`docs/`](docs): start with [architecture and decisions](docs/architecture.md), the [Staging environment](docs/staging.md) and [trusted team work](docs/trusted-staging.md).

## How we build it

Silkwire is built in Silkwire. Jason works with Eve, Claude and Codex in the project's own Collab Room, and much of the code is written by agents and reviewed by teammates, with Jason guiding the work and deciding what ships. We think that's worth saying plainly. It's also why reliability, permissions and honest status labels are our first priorities: we feel every rough edge ourselves.

## Security

Silkwire runs agents that can read files and, with your permission, run commands. Please don't report security problems in public issues. Write to [hello@silkwire.si](mailto:hello@silkwire.si) with "Security" in the subject, and we'll get back to you privately.

## License

Silkwire is released under the [Apache License 2.0](LICENSE). See [`NOTICE`](NOTICE) for attributions, including the bundled Archivo font, which keeps its own SIL Open Font License.

<p align="center">
  <sub>© 2026 RocketShift LLC · Created by Jason Armstrong</sub>
</p>
