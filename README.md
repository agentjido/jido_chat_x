# Jido Chat X

[![Hex.pm](https://img.shields.io/hexpm/v/jido_chat_x.svg)](https://hex.pm/packages/jido_chat_x)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_chat_x/)
[![CI](https://github.com/agentjido/jido_chat_x/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_chat_x/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_chat_x.svg)](https://github.com/agentjido/jido_chat_x/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)

`jido_chat_x` provides a stateless X Direct Messages adapter for Jido Chat V3.
It uses [`xdk-elixir`](https://github.com/mikehostetler/xdk-elixir) for provider
I/O.

## Local V3 setup

The V3 release is not published. Use the sibling Jido Chat source while you
develop and test the stack:

```elixir
def deps do
  [
    {:jido_chat, path: "../jido_chat"},
    {:jido_chat_x, path: "../jido_chat_x"}
  ]
end
```

Replace local paths with released Hex constraints only after the V3 packages
are published.

## Client setup

Provider resources stay in the local immutable Client value. They do not enter
request, result, or inbound Signals.

```elixir
client =
  Jido.Chat.Client.new!(Jido.Chat.X.Adapter,
    id: "support-x",
    config: [xdk_client: my_xdk_client]
  )
```

The host owns X authentication and the `Xdk` client lifecycle. The adapter
starts no process.

## Typed operations

Use Jido Chat operations with the configured Client:

```elixir
{:ok, sent} = Jido.Chat.send_text(client, x_user_id, "Hello")

{:ok, page} =
  Jido.Chat.Signal.Policy.new!(Jido.Chat.Signal.FetchMessages, %{
    "client_id" => client.id,
    "request_id" => "history-1",
    "room_id" => "conversation:12345"
  })
  |> then(&Jido.Chat.execute(client, &1))
```

The adapter supports these native operations:

- `send_message`
- `delete_message`
- `fetch_message`
- `fetch_messages`
- `open_dm`

All other core operations return a typed `not_attempted` result without
provider I/O.

## Inbound delivery

The host verifies and acknowledges the X webhook. Then it normalizes one
complete verified provider input unit:

```elixir
{:ok, delivery} = Jido.Chat.normalize(client, verified_x_payload)

Enum.each(delivery.signals, fn signal ->
  # Apply the fact through the host-owned Jido Chat runtime or application flow.
end)
```

Normalization is deterministic. It keeps provider item order, gives each item
a stable identity, and turns unsupported provider items into explicit
normalization-failure facts.

## Runtime ownership

Jido Chat core owns the optional managed Room and provider runtime. This
adapter owns only X request mapping, response mapping, and input normalization.
It does not start a listener, room process, persistence process, or second
messaging tree.

## Offline checks

```bash
mix test
mix test.contracts
mix quality
mix docs -f html -f markdown
```

Normal tests use fixed transports and make no X request. Live tests are tagged
and excluded by default.

## Live checks

Set `RUN_LIVE_X_TESTS=true` with OAuth 1.0 credentials to run the read-only
credential check. Set `RUN_LIVE_X_SEND_TESTS=true` and
`X_TEST_RECIPIENT_ID` only when you also intend to create a real direct
message.

```bash
mix test --include live
```

## Documentation

Run `mix docs -f html -f markdown`. The command creates HTML documentation and
`doc/llms.txt`.
