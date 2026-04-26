# Jido Chat X

`jido_chat_x` adapts X/Twitter Direct Messages to the `Jido.Chat.Adapter` contract.

The adapter is built on [`xdk-elixir`](https://github.com/mikehostetler/xdk-elixir) for API calls.

## Feature surface

- Numeric X user ids can be used as outbound DM rooms.
- Existing DM conversations use `conversation:{dm_conversation_id}`.
- `send_message/3` sends text DMs by participant id or conversation id.
- `post_message/3` sends text/markdown payloads as plain DM text.
- `send_file/3` supports remote file/media URLs by appending links to the DM text.
- Local file paths and in-memory binary uploads are intentionally rejected until the media upload flow is live-tested.
- `fetch_message/3`, `fetch_messages/2`, and `delete_message/3` use the XDK Direct Messages API.
- `open_dm/2` returns the numeric user id as a sendable DM room.
- Account Activity webhooks verify CRC and POST signatures, parse DM events, and route through `Jido.Chat.process_event/4`.

X Direct Messages do not support message edits, reactions, modals, or ephemeral messages through this adapter.

## Live testing

Set:

```bash
RUN_LIVE_X_TESTS=true
X_CONSUMER_KEY=
X_CONSUMER_SECRET=
X_ACCESS_TOKEN=
X_ACCESS_TOKEN_SECRET=
X_TEST_RECIPIENT_ID=
```

The authenticated X user must be able to send a DM to `X_TEST_RECIPIENT_ID`.

Run:

```bash
mix test --include live
```

## Webhook setup

X Account Activity webhooks are required for real-time DM ingress.

- Configure a webhook URL for your runtime route, for example `/api/webhooks/x`
- The route must answer CRC GET checks with an HMAC-SHA256 `response_token`
- POST requests must be verified with `x-twitter-webhooks-signature`
- Subscribe the authenticated user account to Account Activity events

The adapter deduplicates should be handled by the runtime using the DM event id.
