# External Command Audit for LifeOS

## Goal

Audit the mirrored external command tree and decide what LifeOS should copy,
adapt, or ignore.

This document is not a product spec for vendor integration. It is a pragmatic
adoption filter for LifeOS.

## Bottom line

The mirrored command tree is useful as a reference implementation for:

- context compaction
- per-session planning UX
- background task UX
- MCP management UX
- review command ergonomics

It is not a good base to ingest wholesale because the tree is strongly coupled
to Anthropic-specific auth, remote-control flows, telemetry, feedback, and
transcript-sharing surfaces.

Treat it as a pattern library, not as a foundation.

## Important constraints

### 1. Not a clean standalone base

The mirrored command tree does not appear to be a clean source package by
itself.
Many files are already transformed with `react/compiler-runtime` and inline
source maps. That means it is risky to treat this directory as the canonical
upstream source for direct integration work.

### 2. Remote-first assumptions conflict with LifeOS

The tree includes:

- remote-control bridge flows
- upstream proxy / MITM relay for remote sessions
- feedback submission to Anthropic
- transcript sharing
- privacy settings tied to Anthropic account behavior

LifeOS should not inherit these as product defaults.

### 3. LifeOS already has several equivalent foundations

LifeOS already ships real foundations for many of the same concepts:

- AI runtime and local model management in `cli/src/commands/ai.rs`
- context profiles in `daemon/src/context_policies.rs`
- local encrypted memory in `daemon/src/memory_plane.rs`
- skill registry in `daemon/src/skill_registry.rs`
- persistent task queue in `daemon/src/task_queue.rs`
- permission broker in `daemon/src/permissions.rs`
- supervisor/orchestration in `daemon/src/supervisor.rs`
- MCP server surface in `daemon/src/mcp_server.rs`
- agent and intent runtime in `daemon/src/agent_runtime.rs`

So the right question is not "can we import upstream commands?".
The right question is "which UX patterns fill real LifeOS gaps?".

## Command matrix

### Adapt now

These commands have real product value and map cleanly to open LifeOS gaps.

#### `compact`

Source intent:

- clear history while keeping a summary in context

Why it matters:

- directly aligned with Fase BJ and the need for explicit context compression
- LifeOS has memory and context policies, but it does not yet expose a focused
  user-facing "compact this conversation" command

Recommendation:

- implement a LifeOS equivalent first
- likely surface: `life assistant compact` or `life ai compact`
- backend should use explicit token budgets, summary artifacts, and safe
  boundaries rather than raw history truncation

#### `plan`

Source intent:

- enable plan mode or inspect current plan

Why it matters:

- LifeOS already has orchestration and workflows, but it lacks a lightweight
  per-session planning control surface comparable to the upstream CLI UX

Recommendation:

- adapt as a session-level plan state viewer/editor
- keep it local-first and store plan state in daemon/session context

#### `tasks`

Source intent:

- list and manage background tasks

Why it matters:

- LifeOS already has a persistent queue and supervisor, but user-facing task
  management is still thinner than it should be

Recommendation:

- add a dedicated CLI surface over the existing task queue and supervisor
- expose list, inspect, cancel, retry, and logs

#### `mcp`

Source intent:

- manage MCP servers

Why it matters:

- LifeOS has an MCP server, but the user-facing management layer is still
  weaker than the command suggests

Recommendation:

- adapt the management UX, not the Anthropic-specific wiring
- useful subcommands: list, enable, disable, verify, doctor

#### `review`

Source intent:

- local PR review prompt flow

Why it matters:

- the local `review` command is simple, useful, and mostly vendor-neutral
- it fits well with LifeOS local model and remote-optional policy

Recommendation:

- copy the command concept, not the exact implementation
- wire it to local review heuristics and LifeOS provider routing

### Already covered in LifeOS

These are not high-leverage imports because LifeOS already has equivalent or
broader foundations.

#### `skills`

- LifeOS already has CLI skill generation, install, verify, run, export, and
  doctor flows in `cli/src/commands/skills.rs`
- value here is only minor UX inspiration

#### `memory`

- LifeOS already has a richer local encrypted memory plane than the external
  command surface implies
- adopt only presentation ideas if needed

#### `permissions`

- LifeOS already has a brokered permission model and a CLI around stored grants
- do not replace it with an upstream bypass-oriented UX

#### `status`

- LifeOS already has system status, AI status, voice status, and daemon-backed
  operational commands
- maybe borrow layout ideas, not architecture

#### `voice`

- LifeOS already has a much stronger voice pipeline surface than this command
- no import value beyond small UI copy ideas

#### `context` and `config`

- LifeOS already has context policies and configuration surfaces
- useful only as reference for interaction polish

### Do not inherit

These commands or surfaces conflict with LifeOS direction or are too tied to
Anthropic-specific infrastructure.

#### Remote / account-coupled

- `remote-control`
- `bridge-kick`
- `remote-env`
- `session`
- `share`
- `login`
- `logout`
- `install-github-app`
- `install-slack-app`
- `chrome`
- `mobile`

Reason:

- these are tied to remote bridge/account/product surfaces that are not part of
  LifeOS local-first architecture

#### Commercial / telemetry / growth

- `feedback`
- `privacy-settings`
- `usage`
- `extra-usage`
- `passes`
- `stickers`
- `think-back`
- `thinkback-play`

Reason:

- these are product-growth features, not core runtime capabilities
- some of them directly move data or preferences into Anthropic-specific flows

#### Unsafe defaults or wrong posture

- bypass-permission related UX patterns
- remote transcript sharing patterns
- upstream proxy patterns

Reason:

- LifeOS should not normalize permissive or remote-first safety posture

## Best adoption order

If LifeOS wants to learn from the mirrored command tree, the order should be:

1. `compact`
2. `tasks`
3. `mcp` management UX
4. `plan`
5. `review`

This order is deliberate:

- `compact` directly improves small-model quality
- `tasks` exposes infrastructure that LifeOS already has
- `mcp` improves control-plane usability
- `plan` improves orchestration ergonomics
- `review` is useful but not foundational

## Concrete mapping to LifeOS

### Best first implementation

`compact` should map to:

- daemon-side summarization + context checkpointing
- explicit token budget awareness
- optional summary instructions
- future integration with Fase BJ context engineering

### Best near-term UX win

`tasks` should map to:

- `daemon/src/task_queue.rs`
- `daemon/src/supervisor.rs`
- new CLI commands for queue inspection and control

### Best control-plane improvement

`mcp` should map to:

- `daemon/src/mcp_server.rs`
- a new CLI manager rather than a new protocol layer

### Best orchestration UX improvement

`plan` should map to:

- session-level plan state
- specialist routing visibility
- background execution boundaries

### Best reusable local command

`review` should map to:

- local PR review prompt scaffolding
- LifeOS provider routing
- local-first review policy by default

## Recommendation

Do not spend time trying to port vendor commands as a package.

Do this instead:

- cherry-pick the command semantics
- re-implement them on top of LifeOS runtime
- keep local-first, privacy-first, and hardware-aware behavior as the default

That path gives LifeOS the useful UX without importing the wrong platform
assumptions.
