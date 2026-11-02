# Native OpenClaw Gateway boundary

Silkwire's `NativeEveTransport` is Swift application code using Foundation
`URLSessionWebSocketTask`. It does not embed the Gateway, execute Node, load an
SDK bundle, or discover another product's installation.

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
The app neither changes sign-in nor modifies Gateway permissions. Gateway error
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
