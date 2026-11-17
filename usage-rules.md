# LLM Usage Rules for Jido Chat X

`jido_chat_x` adapts X Direct Messages to `Jido.Chat.Adapter`.

- Build API calls on `xdk-elixir`; keep raw HTTP wrappers small and temporary.
- Keep XDK clients and private transport settings in `Jido.Chat.Client.config`.
- Use typed Jido Chat requests, results, and normalized facts at the package boundary.
- Keep Room, provider runtime, storage, retries, and listener ownership in Jido Chat or the host.
- Treat X webhook CRC and POST signatures as required in live systems.
- Live tests must stay opt-in with `RUN_LIVE_X_TESTS`.
