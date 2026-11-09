# Native OpenClaw Gateway boundary

Silkwire's `NativeEveTransport` is Swift application code using Foundation
`URLSessionWebSocketTask`. It does not embed the Gateway, execute Node, load an
SDK bundle, or discover another product's installation.

## Prerequisites

These are requirements read from the connector at public commit
`c5508f3d717790c58f52e57c38b07d2faa0a26be`, not a live integration result.
The November 9, 2026 fresh-download check built the app only; it did not connect
to a Gateway or establish a known-compatible OpenClaw release.

Before connecting Eve, prepare these in your own OpenClaw setup:

- A separately installed, configured and running Gateway. Silkwire does not
  install, configure or start it.
- The default file `~/.openclaw/openclaw.json`, containing `gateway.mode` set
  to `local`, `gateway.auth.mode` set to `token`, and a nonempty
  `gateway.auth.token`. Do not share the token. Alternate config paths and
  remote or password-mode Gateways are not supported by this connector.
- A listener at `ws://127.0.0.1:<port>`, using `gateway.port` (default `18789`).
- Wire protocol **exactly 4** and the `gateway-client` / `backend` connection
  contract described below, with effective `operator.read` and
  `operator.write` scopes.
- An agent with ID **`main`**. Eve's agent ID and room-session namespace are
  fixed to `main`; the app does not select an arbitrary configured agent.
- For Staging, also `operator.admin` scope and support for `sessions.create`,
  `sessions.patch` and `tools.effective`, including the session-specific
  read-only/wildcard-deny policy. Unconfirmed restrictions block dispatch.

Review the authority boundary below as well as the connection requirements.
A successful app build does not establish that an existing Gateway meets them.

## Supported contract

The implementation follows OpenClaw's published **wire protocol v4**, rather
than porting undocumented SDK internals:

- <https://docs.openclaw.ai/gateway/protocol/handshake>
- <https://docs.openclaw.ai/gateway/protocol/auth>
- <https://docs.openclaw.ai/gateway/protocol/transport>
- <https://docs.openclaw.ai/gateway/protocol/rpc-session-control>

It waits for `connect.challenge`, advertises exactly `[4,4]`, checks the
`hello-ok` protocol and effective operator read/write grant, and correlates RPC
response IDs with bounded deadlines. It uses the documented, reserved
direct-loopback `gateway-client` / `backend` helper trust path. This is restricted
to `127.0.0.1` and an existing local token-mode Gateway configuration. A custom
backend identity or remote endpoint is not silently substituted.

The existing `.openclaw/openclaw.json` token is read into process memory only.
It is not copied into Silkwire resources, defaults, receipts, logs, or tests.
The normal connector leaves sign-in and existing Gateway permissions unchanged;
Staging applies the session-specific restrictions described below. Gateway error
text is not surfaced; only constrained uppercase machine codes are displayed.
Usage is **not reported**, not guessed to be unlimited or available.

## Session and outcome invariants

- Existing `agent:main:silkwire-native-dev:<conversation UUID>:collab` identities
  remain stable so the independent app does not strand native conversation
  history. The historical `native-dev` namespace is a compatibility identity,
  not a source/runtime lookup.
- A fresh mismatched identity is replaced with that room's exact dedicated key.
- `chat.send` occurs once per requested turn, with one fresh idempotency key.
  A lost acknowledgement is **never** retried as another send.
- Events must match both dedicated session and exact run. Duplicate run-local
  payload sequences are discarded. An outer connection sequence gap retires
  the live baseline, reconnects, and reconciles from exact history.
- A final frame alone does not prove completion: the runtime must report no
  active direct runs or pending queued inputs, and the matching assistant run
  must have a terminal stop reason. `chat.message.get` confirms the full text
  and exact run identity before the app reports a completed response.
- Yield is failure-to-finish, not completed work. Unknown outcomes retain the
  persisted request/run identity for recovery and block a new turn.
- Stop targets only the owned saved/current run ID, then requires idle
  confirmation. Closing a view/socket does not invent an outcome or replay.
- Reconnect uses bounded backoff. A three-minute reply watchdog reports an
  unconfirmed result rather than a fabricated final answer.

## Authority boundary

The Gateway connector preserves the pre-existing OpenClaw agent's authority.
Its conversation-only/no-tools preamble is an **instruction**, not a new
server-side tool sandbox. Silkwire's own Project text broker independently
checks current shared Project grants for every access; this transport does
not claim that its prompt revokes unrelated Gateway tool permissions.

**Staging is different:** the dedicated subagent-shaped Staging session receives
an enforced wildcard tool deny and read-only permission. Its empty effective
tool inventory is checked before dispatch; the installed provider harness also
disables native execution tools under that policy. Working-session identities
are never reused. See [Staging boundaries and acceptance](staging.md). The
working connector remains unchanged; the Staging policy never edits main-agent
configuration, sign-in or the working library.

## Verification

The following are verification procedures, not checks run by the November 9
fresh-download review. That review did not run fixtures, send a live turn, or
validate provider permissions.

Build and run the native Network.framework WebSocket fixtures:

```sh
swiftc -swift-version 5 -O -parse-as-library \
  Sources/Silkwire/Models.swift Sources/Silkwire/WorkspaceEnvironment.swift Sources/Silkwire/AgentTransport.swift \
  Sources/Silkwire/NativeEveTransport.swift Tests/NativeEveTransportTests.swift \
  -o /tmp/silkwire-gateway-tests
/tmp/silkwire-gateway-tests
```

The fixture uses a temporary token-shaped dummy value, an ephemeral local
WebSocket listener, and only synthetic messages. It tests v4 handshake,
room/run/duplicate fencing, authoritative final retrieval, active-runtime final
frames, Stop, yield, lost acknowledgements without replay, connection gaps,
persisted-run recovery/blocking, rejected sends, and honest connection status.

An opt-in real integration check reads the existing local Gateway sign-in and
creates its own UUID-named synthetic session (never owner transcript data):

```sh
SILKWIRE_GATEWAY_LIVE=1 /tmp/silkwire-gateway-tests
```

It sends only a fixed synthetic acceptance instruction and requires
`SILKWIRE_SWIFT_GATEWAY_OK` from the exact run's full durable history.
