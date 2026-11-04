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
- **Your own accounts.** Agents sign in with the subscriptions you already have. Silkwire doesn't resell SI access or see your passwords.
- **You stay in charge.** By default, agents do their work in private copies, and installing, sending, merging or deploying waits for your OK.
- **Saved on your Mac.** Conversations live on your computer. Agents read the folders you grant them. Letting an agent operate your Mac directly is a separate, stronger permission you choose to give.
- **Alexandria and Future.** A shared library for plans and decisions, and a place to pin what the project is aiming for.

It's built for people who have never opened a terminal. You bring the taste and make the call; the team does the work.

## Where we are

We label every feature honestly. Only the first label means it actually runs.

| Feature | Status |
|---|---|
| Collab Room and one-on-one rooms | ✅ Works in our build |
| Claude, Codex and Eve (an [OpenClaw](https://github.com/openclaw/openclaw) agent) as teammates | ✅ Works in our build |
| Asking first before risky actions like installing, sending or deploying | ✅ Works in our build |
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

Requirements: macOS 14 or later, and Apple's Swift toolchain (Xcode or the Command Line Tools).

Clone this repository with Git using the green **Code** button above, then from its folder run the command below. Download ZIP won't work, because the build needs the Git history.

```bash
swift Scripts/build.swift
```

The app is built into `output/release/Silkwire Dev.app`. To talk to agents, install the official Claude and Codex command-line tools and sign in with your own accounts; Eve connects through a local [OpenClaw](https://github.com/openclaw/openclaw) Gateway. Silkwire reuses those sign-ins and never copies them.

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
