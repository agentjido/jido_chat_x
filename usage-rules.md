# LLM Usage Rules for Jido Chat X

`jido_chat_x` adapts X Direct Messages to `Jido.Chat.Adapter`.

- Build API calls on `xdk-elixir`; keep raw HTTP wrappers small and temporary.
- Treat X webhook CRC and POST signatures as required in live systems.
- Live tests must stay opt-in with `RUN_LIVE_X_TESTS`.
