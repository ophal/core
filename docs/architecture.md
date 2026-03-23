# Architecture Review: `master` vs `0.1`

## Scope

This document summarizes the architectural differences between the `master`
and `0.1` branches in this repository. It is based on branch history and source
inspection, with emphasis on subsystem boundaries, extensibility, and risk.

The branches diverged from commit `ae082d4` (`Bug fix: validation fails on
content update.`). At review time, `0.1` is 54 commits ahead of that split and
`master` is 23 commits ahead.

## Executive Summary

`master` is the simpler branch. It stays closer to a feature-module model with
less indirection and fewer shared abstractions.

`0.1` is the branch where the architecture materially evolves. It introduces a
generic entity layer, route mutation hooks, stronger database guardrails, and a
refactored user and permission model. That makes it a better base for an
extensible platform, but it also leaves the codebase in a hybrid state where
legacy feature-specific flows and the new generic entity flows coexist.

## Branch Shape

The `master` branch appears to be a short maintenance line after the project
was marked unmaintained. The `0.1` branch continues development and contains
the meaningful architectural work.

Top-level shape is mostly stable across both branches:

- Core runtime under `includes/`
- Feature modules under `modules/`
- Themes under `themes/`
- Browser assets under `libraries/`

The main structural file-level difference is the addition of
`modules/entity/init.lua` on `0.1`.

## Major Architectural Differences

### 1. Shared Entity Layer in `0.1`

The largest change is the introduction of a shared entity subsystem in
[`modules/entity/init.lua`](/sandbox/modules/entity/init.lua). It adds:

- Generic routes for create, edit, delete, save, and remove
- A shared `entity_access()` model
- Centralized entity type discovery through `entity_type_info`
- Cross-module helpers such as `entity_after_save` and `entity_after_delete`

This shifts the design away from purely feature-owned CRUD flows toward a more
framework-like model where content types can participate in common lifecycle
and routing behavior.

By comparison, `master` is more direct: content, tags, and users primarily own
their own routing and persistence behavior with less shared infrastructure.

### 2. Route Construction Becomes Extensible

`0.1` adds a `route_alter()` hook during route build in
[`includes/route.lua`](/sandbox/includes/route.lua). The entity module uses
that hook to inject default entity routes for modules that do not define one
themselves.

Architecturally, this is a move from static route declaration to a
route-construction pipeline:

- Modules declare routes
- Other modules can mutate those routes
- Final handlers are built afterward

That is more flexible than `master`, but it also increases hidden coupling
between modules.

### 3. Database Layer Adds Schema-Aware Guardrails

`0.1` strengthens the database layer in
[`includes/database/init.lua`](/sandbox/includes/database/init.lua) and
[`includes/database/postgresql.lua`](/sandbox/includes/database/postgresql.lua):

- DB connection failures now raise immediately
- Query execution failures now raise immediately
- A new `db_field()` helper validates field names against database schema

This is a real architectural improvement over `master`. It reduces accidental
SQL injection surface in dynamic lookup paths such as user and comment loading,
and it moves validation closer to the persistence boundary.

### 4. User and Permission Model Is Refactored

`0.1` changes the auth model in
[`modules/user/init.lua`](/sandbox/modules/user/init.lua):

- Session stores `user_id` instead of a whole user object
- User objects are loaded on demand
- Roles and permissions are resolved through helper functions and caches
- `user_login` hooks can mutate authentication output

Compared with `master`, this is a cleaner separation between session state,
identity loading, and authorization. It also aligns better with the new entity
direction, since users become a loaded entity rather than a fully embedded
session blob.

### 5. Feature Modules Start Converging on Entity Semantics

`0.1` updates modules such as content, tag, comment, and user to participate in
entity lifecycle hooks or entity-style access decisions:

- [`modules/content/init.lua`](/sandbox/modules/content/init.lua)
- [`modules/tag/init.lua`](/sandbox/modules/tag/init.lua)
- [`modules/comment/init.lua`](/sandbox/modules/comment/init.lua)
- [`modules/user/init.lua`](/sandbox/modules/user/init.lua)

This is not a full migration. The branch still mixes:

- Feature-owned routes and save handlers
- Shared entity routes and callbacks
- Feature-local access rules
- Generic entity access rules

That makes `0.1` more capable, but also less uniform than a fully completed
framework refactor.

## Findings

### High Severity

1. Generic relation cleanup in the entity layer appears structurally wrong.

In [`modules/entity/init.lua`](/sandbox/modules/entity/init.lua), deletion
cleanup iterates `pairs((config[entity.type] or {}).parents)` and uses the loop
variable as the parent type when building relation table names. Earlier in the
same module, `parents` is treated as a list of values, not keys. If that config
is an array, cleanup will target relation tables like `rel_<type>_1` instead of
real relation names.

This matters because the new entity abstraction is supposed to centralize
cross-entity lifecycle behavior. If relation cleanup is wrong, the shared
deletion model is not trustworthy.

### Medium Severity

2. Route mutation increases indirection without deterministic ordering.

`0.1` still builds initial route sets by iterating `pairs(ophal.modules)` in
[`includes/route.lua`](/sandbox/includes/route.lua), while route definitions can
now be mutated by other modules via `route_alter()`.

The design is flexible, but it makes final route shape depend on Lua table
iteration order. That is not a strong base for a framework-level extension
point.

3. User, role, and permission caches have no visible invalidation strategy.

The caches in [`modules/user/init.lua`](/sandbox/modules/user/init.lua) are an
architectural improvement for repeated lookups, but they are process-local and
do not show a coherent reset policy when roles or permissions change.

In short-lived CGI execution this is probably acceptable. In a persistent
server model it would be a stale-data risk.

4. The entity migration is incomplete.

`0.1` introduces a shared entity core, but content and tag modules still own
significant amounts of routing and save logic directly. This means the branch
contains two architectural styles at once:

- Legacy feature-owned flows
- New framework-owned entity flows

That raises maintenance cost and increases the chance of behavior divergence.

### Low Severity

5. Error handling style is mixed after the database refactor.

The database layer now raises on failure, but many call sites still assign
`local rs, err = db_query(...)` as if they expect old-style explicit error
returns. That is mostly harmless, but it shows the architectural transition is
not fully normalized through the codebase.

## Practical Comparison

### `master`

Use `master` if the priority is:

- Smaller mental model
- Lower indirection
- Easier local reasoning
- Fewer shared abstractions

### `0.1`

Use `0.1` if the priority is:

- Extensibility
- Shared entity lifecycle behavior
- More framework-like module integration
- Better long-term platform direction

The tradeoff is that `0.1` is more internally coupled and still mid-refactor.

## Recommendation

If the goal is to continue evolving Ophal as a platform, `0.1` is the more
important branch. It contains the meaningful architectural direction:
generalized entities, more reusable routing, and a stronger data-access
boundary.

If the goal is to stabilize or audit a simpler system, `master` is easier to
reason about. It is architecturally narrower and avoids the hybrid state
introduced by the `0.1` refactor.
