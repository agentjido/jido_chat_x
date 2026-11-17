# Jido Chat V3 validation: X

Date: 2026-11-16 (America/Chicago).

## Scope

The X `release/v3` branch is validated against the current sibling
`../jido_chat` working tree. The core uses consolidated Jido V3. This is local
integration evidence. It is not Hex publication or live provider evidence.

The adapter keeps these V3 boundaries:

- one stateless `Jido.Chat.Adapter`;
- strict native or unsupported capability values;
- typed core request, result, and inbound Signals;
- an XDK client in local `Client.config`;
- no process, listener, storage, or room ownership in the adapter;
- managed Room and provider runtime ownership in Jido Chat core.

## Current migration changes

- Replaced the fixed remote Jido Chat source with `path: "../jido_chat"` for
  every local environment.
- Removed the stale Jido Chat lock entry and selected the consolidated Jido V3
  commit required by the local core.
- Replaced the removed client option helper with explicit Client config and
  per-call options.
- Kept XDK query options behind a small allowlist and translated Chat cursors
  and limits at the transport boundary.
- Made message-page and normalization list construction linear.
- Removed an avoidable entry-point and adapter dependency cycle.
- Added explicit contract and coverage gates and focused offline tests.
- Replaced stale binding, source-pin, fallback-capability, and separate
  Messaging runtime documentation with the current Jido Chat V3 contract.

## Offline evidence

Normal tests use fixed transports and make no X network request. Live tests
keep the `:live` tag and remain excluded by default.

The current result is 15 offline tests passed and two live tests excluded. The
Adapter Test Kit gate passes 12 tests. Built-in coverage is 96.05%. Quality,
strict Credo, HTML and Markdown documentation, production compile, unused
dependency, dependency-tree, retired-reference, diff, and design-review checks
pass. The final xref graph has 6 files, 5 runtime edges, no compile edges, and
no cycles.

## Dependency boundary

```text
jido_chat_x
└── jido_chat (path: ../jido_chat)
    └── jido (consolidated V3 source selected by Jido Chat)
```

The adapter lock contains no Jido Chat remote source. Package publication must
later replace the local path with the released Jido Chat V3 Hex constraint and
repeat the same gates.

## Live evidence

No live or paid provider call ran. X credentials, permissions, remote delivery,
webhooks, and external service behavior are not verified by this local unit.
