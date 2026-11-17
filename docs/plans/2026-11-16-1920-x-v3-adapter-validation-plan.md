---
title: X adapter current Jido Chat V3 validation
type: implementation-plan
date: 2026-11-16
last_reviewed: 2026-11-16
artifact_contract: kata-plan/v1
artifact_readiness: complete
domain: software
execution: code
product_contract_source: approved-goal
---

# X Adapter Current Jido Chat V3 Validation

## Goal Capsule

- Objective: Make the X `release/v3` migration work with the current local
  Jido Chat V3 source and leave no retired messaging dependency, ownership
  reference, or obsolete core API.
- Means: Select the sibling Jido Chat package, use the current immutable Client
  fields, keep the XDK client behind the transport boundary, correct stale
  documentation, add focused offline contract evidence, and complete an Elixir
  design review.
- Authority: Local X adapter and Jido Chat checks and local X adapter edits. No
  live X request, credential use, commit, push, release, or remote update.
- Stop conditions: Stop before provider I/O, a provider branch in core, a
  second process tree, or a compatibility API.
- Next executor: Elixir package engineer.

## Starting Evidence

- `release/v3` starts clean at `9ebab39` and matches `origin/release/v3`.
- The branch already uses the current adapter, Action, request, result,
  Delivery, and Adapter Test Kit shapes.
- It still selects an older fixed Jido Chat Git source and calls the removed
  merged-client-options helper.
- The normalizer builds output lists with repeated append.
- The package entry point and adapter form a two-module event-definition
  dependency cycle.
- The README and validation report describe removed binding and Messaging
  acceptance APIs, old source pins, and old capability statuses.
- `origin/main` contains a newer `git_ops` lock update. The dependency refresh
  must preserve that update without merging unrelated branch history.

## Product Contract

- **R1:** Every local environment selects `path: "../jido_chat"` and the lock
  resolves consolidated Jido V3 at the source selected by that package.
- **R2:** The XDK client stays in `Client.config`. Per-call options can override
  adapter config, but credentials and the client never enter request or result
  Signals.
- **R3:** The adapter remains stateless and exposes only current
  `:native | :unsupported` capabilities.
- **R4:** Send, delete, fetch-one, fetch-page, and open-DM operations use current
  typed request and result Signals. Unsupported operations stop before I/O.
- **R5:** Direct-message input produces stable ordered facts or explicit item
  failures. Provider result and paging failures are deterministic.
- **R6:** The default XDK transport sends only supported X query options to XDK.
- **R7:** Documentation states the current V3 API, local dependency boundary,
  capability set, and Jido Chat runtime ownership.
- **R8:** Normal tests make no live X call. Live tests remain tagged and
  excluded.
- **R9:** Tests, contracts, coverage, quality, docs, production compile, unused
  dependencies, compile graph, dependency tree, source scan, diff check, and
  design review pass.

## Implementation Units

1. Replace the fixed Jido Chat Git dependency with the sibling local path,
   refresh the lock, and preserve the current `git_ops` lock update.
2. Replace the removed client helper with explicit Client config and per-call
   options. Add direct option-boundary and provider-result tests.
3. Make list construction linear and remove the entry-point/adapter dependency
   cycle.
4. Replace obsolete binding, capability, source-pin, and separate Messaging
   runtime documentation with current local V3 guidance.
5. Run all offline gates and an Elixir design review, fix supported findings,
   and repeat affected checks.

## Verification Contract

Run from `/Users/mhostetler/Source/Jido/jido_chat/jido_chat_x`.

- The normal suite excludes `:live` and makes no provider request.
- Contract, coverage, quality, docs, production compile, unused dependency,
  xref cycle and stats, dependency tree, and diff checks pass.
- The dependency tree resolves Jido Chat from `../jido_chat` and consolidated
  Jido V3 at `ec96da6015b4b1e5a1642d50651235d9d52808ec`.
- Repository search finds no retired package name, removed client helper, old
  V2 constraint, old Jido Chat Git source, or obsolete source commit.
- No accepted Elixir design-review finding remains.

## Risks and Mitigations

- Risk: the XDK client enters request data. Mitigation: keep it in local Client
  config and assert the transport-only boundary.
- Risk: paging options leak adapter-only keys to XDK. Mitigation: test the exact
  query option allowlist.
- Risk: tests call X. Mitigation: preserve live tags and use only fixed
  transports in the normal suite.

## Definition of Done

- R1 through R9 have current evidence.
- X uses the same local Jido Chat V3 tree as completed adapters.
- No live provider check or remote change occurred.

## Execution Result

Completed locally on 2026-11-16 against `release/v3` at unchanged HEAD
`9ebab39`. The adapter selects `../jido_chat`, which selects consolidated Jido
V3 at `ec96da6015b4b1e5a1642d50651235d9d52808ec`. The dependency refresh also
keeps the `git_ops` 2.12.4 update from `origin/main`. No commit or live provider
call occurred.

The normal suite passed 15 tests and excluded two live tests. The explicit
Adapter Test Kit gate passed 12 tests. Coverage is 96.05%. Quality, strict
Credo, HTML and Markdown docs, production compilation with warnings as errors,
unused dependency, dependency tree, source scan, and diff checks passed. The
final xref graph contains 6 files, 5 runtime edges, no compile edges, and no
cycles. Dependency compilation printed warnings from upstream packages; the X
package compiled without a warning.

## Design Review Result

The review traced every package responsibility:

| Responsibility | Success path | Failure path | Status |
| --- | --- | --- | --- |
| Adapter and capabilities | typed native request | unsupported request stops before I/O | traced |
| Operations | send, fetch, delete, open DM | invalid provider result | traced |
| Normalization | ordered stable message facts | explicit invalid and unsupported item facts | traced |
| XDK transport | local loopback XDK requests | missing XDK client and filtered options | traced |
| Dependency boundary | local Chat and consolidated Jido | old source and lock scan | traced |
| Documentation and tests | current examples and offline gates | live tests excluded | traced |

The review found and fixed these issues:

1. **Defect:** Operation dispatch called a removed core Client helper. It now
   merges explicit Client config with per-call options.
2. **Safe refinement:** Message-page and normalized-event loops used repeated
   list append. Both paths now prepend and reverse once.
3. **Safe refinement:** The package entry point and adapter formed an avoidable
   runtime dependency cycle. The entry point now delegates to the adapter,
   which owns its event list.
4. **Safe refinement:** The XDK transport kept obsolete endpoint-absence rescue
   branches and an old generic `:client` alias. The selected XDK dependency
   supplies the endpoints, and V3 has no compatibility path. Both were removed.
5. **Safe refinement:** Contract and coverage gates were implicit, and the real
   XDK request shape was not tested. The package now has an explicit contract
   alias, a coverage gate, and a loopback HTTP test with no external I/O.
6. **Defect:** Public docs described removed binding, normalization, fallback,
   and separate Messaging runtime contracts. The docs now describe the current
   Client, typed Signal, and Jido Chat runtime boundaries.

A final review of the changed state found no remaining actionable issue. The
production patch is net five lines smaller before generated artifacts. The
test growth verifies the provider boundary and offline XDK request shape.
