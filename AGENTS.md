# AGENTS.md - Jido Chat X

This package implements X/Twitter Direct Message support for `Jido.Chat`.

- Core adapter: `Jido.Chat.X.Adapter`
- Default transport: `Jido.Chat.X.Transport.XdkClient`
- API calls should go through `xdk-elixir`.
- Live tests are tagged `:live` and require explicit credentials.

## Release Hygiene

- Do not modify `CHANGELOG.md`; release notes are generated from Git history during release, so keep changes focused on proper Conventional Commits.
