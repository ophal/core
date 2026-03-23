# Ophal Architecture Upgrade Plan

## Scope

This document is the execution follow-up to `docs/architecture.md`. It defines
how to modernize Ophal on top of the active `0.1` branch with the least
possible code churn.

The priorities are, in order:

1. Efficiency through the least possible code change
2. Legacy support for existing modules and programming patterns
3. Performance in both request latency and long-term operability

This is not a rewrite plan. It is a compatibility-first modernization roadmap.

## Branch Baseline

`0.1` is the implementation baseline for the upgrade.

It is already the branch where Ophal materially evolves beyond the maintenance
shape of `master`: it introduces the shared entity subsystem, route mutation
hooks, stronger database guardrails, and the refactored user and permission
model. That is the architecture direction worth stabilizing.

The current `0.1` codebase also makes the main upgrade work clear:

- `includes/bootstrap.lua` still chooses runtime behavior directly and mixes
  bootstrap responsibilities with transport selection.
- `includes/server/init.lua` still combines request parsing, header and cookie
  IO, redirect handling, and platform defaults in one runtime-facing layer.
- `includes/module.lua` has a partially ordered module list, but
  `includes/route.lua` still builds routes by iterating `ophal.modules` with
  `pairs()`, so final route shape is not deterministic.
- `modules/entity/init.lua` is already acting as a shared compatibility layer,
  but it still sits inside a hybrid system where feature modules keep major
  parts of routing and CRUD behavior.
- `modules/user/init.lua` contains process-local permission caches that are
  acceptable for CGI but unsafe to carry unchanged into a persistent runtime.

The plan therefore modernizes `0.1` by tightening the boundaries that already
exist instead of changing platform philosophy.

## Architectural Invariants

The following traits remain part of Ophal's identity and stay in place:

- Module-based architecture
- Hook and alter style extensibility
- Server-rendered HTML as the default delivery model
- Content and entity centric system design
- Integrated routing, forms, permissions, and theming
- SQL-first pragmatism and inspectable source code
- Small-core philosophy with low dependency count

The following are explicitly out of scope:

- Rewriting Ophal into `Lapis` or another framework
- Replacing SQL with an ORM-first persistence model
- Requiring a client-side SPA for admin or site rendering
- Replacing hooks with inheritance-heavy or dependency-injection centric design
- Breaking existing modules without a compatibility wrapper and migration path

## Target Architecture

### 1. Runtime Boundary

The first concrete architecture boundary is a runtime adapter contract. Core
services should no longer care whether the request came from CGI, `ngx`, or a
portable Lua HTTP server.

The adapter contract for `0.2` is:

- `adapter.init(env, settings)`: initialize runtime bindings
- `adapter.request()`: return a normalized request table with `method`,
  `scheme`, `host`, `script_name`, `uri`, `path`, `query`, `headers`,
  `cookies`, and `body`
- `adapter.header(name, value, replace)`: write or append response headers
- `adapter.cookie(name, value, options)`: write response cookies
- `adapter.write(chunk)`: write response body data
- `adapter.redirect(target, status)`: issue redirects
- `adapter.finish(status)`: flush and terminate the response

The request contract is normalized once per request and then treated as the
single source of truth by routing, session, form, and rendering code.

Compatibility rules:

- `includes/server/cgi.lua` remains the reference implementation for the
  contract.
- Existing global helpers such as `header()`, `cookie_set()`, `request_uri()`,
  and output buffering remain available, but they delegate through the active
  adapter.
- After phase 1, feature modules must not depend on `ngx`, raw CGI variables,
  or transport-specific branching.
- `OpenResty` is the first non-CGI adapter target after the CGI contract is
  stable. `lua-http` is optional and only ships if it fits the same contract
  without compatibility exceptions.

### 2. Module Metadata And Hook Order

Ophal keeps hooks and modules, but their execution order becomes explicit and
documented.

Each module may define an optional `modules/<name>/info.lua` file that returns:

- `name`
- `dependencies`
- `weight`
- `capabilities`

Compatibility rules:

- If `info.lua` is missing, Ophal synthesizes metadata from the module name and
  existing `settings.modules` weight.
- Modules that only define `init.lua` remain valid.
- `system` remains the first module unconditionally.

The module resolver uses this order:

1. `system` first
2. Dependency order by topological resolution
3. Ascending `weight` inside each dependency-safe group
4. Ascending module name as the final tie-breaker

Hook and route guarantees:

- Hook invocation order is always the resolved module order unless a hook
  documents a stricter rule.
- `route()` is collected in resolved module order.
- `route_alter(module_name, items)` runs in resolved module order against each
  collected route table.
- Route handlers are finalized only after the alter phase finishes.
- The final route table is frozen after build to prevent late mutation.

Route conflict policy:

- During `0.2` and `0.3`, later modules in resolved order win route conflicts,
  but Ophal must emit a deterministic warning naming the route and both modules.
- Before `1.0`, route conflicts are reviewed and either codified as explicit
  overrides or promoted to hard errors.

### 3. Entity Contract And Migration Rules

The entity subsystem on `0.1` becomes a compatibility layer first, not a forced
rewrite target.

The minimum entity surface for a module that participates in shared entity
behavior is:

- an `entity_type_info()` entry for the entity type
- `load(id)`
- persistence helpers through `create(entity)`, `update(entity)`, and
  `delete(entity)`, or wrapper functions that delegate to shared helpers
- page helpers such as `entity_page()` and `archive_page()` when generic entity
  routes are used
- optional `entity_access(entity, action)` override; otherwise shared entity
  access rules apply

Lifecycle hooks that remain part of the platform contract:

- `entity_load`
- `entity_after_save`
- `entity_after_delete`
- `entity_render`

Migration rules:

- Module-owned routes and service endpoints remain valid until equivalent
  shared-entity behavior exists and has compatibility tests.
- New or substantially refactored features should prefer shared entity helpers.
- Generic entity routes remain wrappers that delegate to module-specific logic
  whenever the module provides its own implementation.

Required fixes before the entity layer expands further:

- Fix relation cleanup in shared entity deletion so parent relation tables are
  addressed by actual parent type, not list index.
- Run entity route injection only inside the declared route alter phase.
- Normalize validation, access, and lifecycle expectations across content, tag,
  comment, and user flows.

### 4. Cache Model

Performance improvements come from deterministic caches, not from replacing the
core architecture.

Required cache layers:

- Module metadata cache
- Route build cache
- Theme and template cache
- Entity read and render cache
- Configuration cache where it supports the above layers

Invalidation rules:

- Module enable, disable, or `info.lua` changes invalidate module metadata and
  route caches.
- Route provider changes invalidate the route cache.
- Theme changes or template timestamp changes invalidate the theme and template
  cache.
- `entity_after_save` and `entity_after_delete` invalidate entity and render
  caches for the affected entity type and entity id.
- Role or permission changes invalidate authorization caches before any
  persistent runtime is considered production-ready.

Ophal should expose a single cache clear entry point that CLI and admin tools
can call instead of maintaining ad hoc cache reset logic.

### 5. Security And Operations Baseline

Security improvements are platform behavior, not optional module style.

Required platform rules:

- CSRF protection on all mutating form and JSON routes that rely on session
  authentication
- Cookie defaults of `HttpOnly` and `SameSite=Lax`, plus `Secure` whenever the
  request scheme is HTTPS
- Default response headers aligned with current Ophal behavior, but documented
  as a runtime contract rather than scattered side effects
- Context-specific escaping in theme and render helpers
- Centralized authorization checks that remain the source of truth across CGI
  and persistent runtimes
- A password hashing review and upgrade path that preserves login compatibility

Operational improvements belong after the runtime, hook, and cache boundaries
are stable:

- Structured logging
- Better error reporting
- CLI for install, migrate, module enable or disable, and cache clear

## Phased Upgrade Roadmap

### Phase 0: Stabilize And Measure

Purpose: define the supported surface before changing behavior.

Deliverables:

- Document supported extension points and unstable internals
- Add compatibility tests around CGI boot, module loading, route resolution,
  authentication, rendering, and entity lifecycle behavior
- Record baseline profiling for bootstrap, routing, rendering, and DB hotspots
- Track known defects that later phases must absorb

Exit criteria:

- CGI request lifecycle is documented end to end
- Core regressions reproduce in tests rather than only through manual checks
- Performance baseline exists for adapter and cache comparisons

### Phase 1: Extract The Runtime Contract

Purpose: decouple core services from CGI assumptions without breaking CGI.

Deliverables:

- Introduce the runtime adapter contract
- Move request parsing, headers, cookies, writes, redirects, and finish logic
  behind the adapter
- Keep CGI as the reference adapter implementation
- Reduce direct runtime branching to adapter selection and bootstrap wiring
- Preserve helper-level compatibility for existing modules and themes

Exit criteria:

- Installer, login, front page, content page, and JSON save routes behave the
  same on CGI as before the refactor
- Core helpers call the adapter contract instead of transport-specific code
- Feature modules no longer need direct runtime checks

### Phase 2: Make Extension Order Deterministic

Purpose: preserve hooks while removing hidden execution instability.

Deliverables:

- Add optional `info.lua` metadata support with compatibility fallback
- Introduce dependency-aware module resolution
- Define stable hook order and hook return expectations
- Replace ad hoc route building with explicit collect, alter, and finalize
  phases
- Emit deterministic route conflict warnings

Exit criteria:

- Repeated runs with the same module set produce the same module order, hook
  order, and route table
- Legacy modules that only ship `init.lua` still load correctly
- Entity route injection works only through the declared alter phase

### Phase 3: Harden The Entity Compatibility Layer

Purpose: make the existing entity direction trustworthy before expanding it.

Deliverables:

- Publish and implement the minimum entity contract
- Normalize shared access, save, delete, and render expectations
- Fix structural defects in shared entity internals
- Keep module-owned routes operational while improving shared wrappers
- Move only new or heavily refactored behavior toward shared entity helpers

Exit criteria:

- Content, tag, comment, and user flows continue to work without route breakage
- Entity lifecycle hooks fire consistently on create, update, and delete
- Shared entity routes and legacy feature routes can coexist for the same type

### Phase 4: Add Cache Infrastructure And The First Persistent Runtime

Purpose: gain practical performance wins after the boundaries are stable.

Deliverables:

- Add module metadata and route caches
- Add template compile and render caching
- Add entity and render cache invalidation through lifecycle hooks
- Expose unified cache clear tooling
- Implement `OpenResty` as the first persistent runtime target

Exit criteria:

- Cold and warm startup and render paths are measurable and improved
- Cache invalidation is correct after module, route, theme, entity, and
  permission changes
- Persistent runtime execution does not serve stale auth, route, or entity data

### Phase 5: Raise Security And Operations Baseline

Purpose: make the framework safer and easier to operate without changing its
core philosophy.

Deliverables:

- Add CSRF protection to all mutating form and JSON flows
- Harden cookie and session defaults
- Review password hashing and define an upgrade path
- Add structured logging and clearer error reporting
- Add CLI support for install, migrate, module enable or disable, and cache
  clear
- Add `lua-http` only if it reuses the stable runtime contract without special
  handling

Exit criteria:

- Mutating routes reject missing or invalid CSRF tokens
- Session behavior remains compatible on CGI and `OpenResty`
- Common operations no longer require ad hoc scripts or code edits
- Runtime, module, and entity contracts are stable enough for `1.0` support
  documentation

## Release Framing

A practical release framing is:

- `0.2`: phases 0 through 2 complete. CGI contract extracted, extension order
  deterministic, compatibility suite in place.
- `0.3`: phases 3 and 4 complete. Entity layer hardened, core caches present,
  `OpenResty` adapter available.
- `1.0`: phase 5 complete. Security baseline, CLI tooling, stable compatibility
  contracts, documented upgrade path.

`lua-http` is explicitly post-`0.3` and should ship only if it shares the same
adapter and cache contracts without one-off exceptions.

## Cross-Phase Acceptance Scenarios

The roadmap is only complete if these scenarios are validated along the way:

- Existing CGI boot works with the current enabled module set
- Module order, hook order, and route tables are identical across repeated runs
- Legacy feature routes and shared entity routes both resolve when expected
- Entity create, update, and delete operations fire the correct lifecycle hooks
- Cache invalidation restores correctness after module, route, theme, entity,
  and permission changes
- Persistent runtime execution invalidates auth caches when roles or
  permissions change
- Mutating routes enforce CSRF and preserve current authenticated admin flows
- No feature module depends directly on `ngx` or raw CGI variables once phase 1
  is complete

## Decision Summary

If efficiency, legacy support, and performance remain the priorities, the
implementation decision stays simple:

Modernize around adapters, deterministic contracts, compatibility wrappers, and
caches.

Do not modernize by replacing Ophal's module, hook, SQL, and server-rendered
core.

The correct 2026 version of Ophal is the current `0.1` direction made explicit,
deterministic, cache-aware, and safe to run beyond CGI.
