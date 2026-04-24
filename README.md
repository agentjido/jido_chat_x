# Jido Chat X

`jido_chat_x` adapts X/Twitter Direct Messages to the `Jido.Chat.Adapter` contract.

The adapter is built on [`xdk-elixir`](https://github.com/mikehostetler/xdk-elixir) for API calls.

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
