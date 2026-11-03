# Silkwire 🕷️

**You and your agents. Connected.**

Silkwire is a Mac app that brings the super-intelligent (SI) teammates you already use, like Claude, Codex and OpenClaw, into one room, signed in with your own accounts. Tell them what you dream of making, and they work it out with you, and with each other, until it's real.

Our mascot is Ari, a small spider who walks the wire between you and your team.

> **Status: early development.** Silkwire is not ready for everyday use yet. Things change quickly, some connections are unfinished, and there is no signed download. We're sharing the source early so curious people can follow along and help.

## What it does

- **One room, several agents.** Claude, Codex and agents you run on OpenClaw can talk with you and with each other in a shared conversation.
- **Your own accounts.** Silkwire uses the official command-line tools you've already signed in to. It never sees or stores your passwords.
- **Safe hands-on work.** Agents can read the project folders you choose and make changes in private copies. Anything risky, like installing, sending, deleting or deploying, waits for your OK.
- **Native Mac app.** Written in Swift with SwiftUI and AppKit. No web views in the core app, no bundled third-party packages.

## Requirements

- macOS 14 or later
- Apple's Swift toolchain (Xcode or the Command Line Tools)
- Optional, for agents: the official [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://github.com/openai/codex) command-line tools, and/or a local [OpenClaw](https://openclaw.ai) gateway, each signed in with your own account

## Build

Clone the repository (the build reads Git metadata, so a downloaded ZIP won't build):

```sh
git clone <this repository>
cd silkwire
swift Scripts/build.swift
```

The app appears at `output/release/Silkwire Dev.app`. Run the tests with:

```sh
swift Scripts/test.swift
```

More detailed build, verification and Staging notes are in [docs/developer-notes.md](docs/developer-notes.md), and the design is described in [docs/architecture.md](docs/architecture.md).

## Known limitations

- The app still assumes a single, named user in several places; making this configurable is on the list.
- Clean-machine setup hasn't been independently verified yet.
- Builds are signed ad hoc, so macOS Gatekeeper will warn on other Macs.

## Contributing

We'd love help, especially from people who care about motion, typography and calm interfaces. See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem privately, see [SECURITY.md](SECURITY.md).

## License

Silkwire's source code is licensed under the [Apache License 2.0](LICENSE). The bundled Archivo font is licensed separately under the [SIL Open Font License 1.1](Resources/Assets/Fonts/OFL.txt). See [NOTICE](NOTICE) for details.

Follow along at [@SilkwireApp](https://x.com/SilkwireApp) and [silkwire.si](https://silkwire.si).
