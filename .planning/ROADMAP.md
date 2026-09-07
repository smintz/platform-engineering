# Roadmap: Platform Engineering

## Overview

Four new stakeholders — FinOps, database consumers, service mesh, and security — get the same
automatic fan-out that SLOs already prove for monitoring: a developer declares one thing, and
every other stakeholder's concern follows without them naming it. The foundations this all builds
on are not yet trustworthy (compile/apply drift, no shape-selectable component field, unchecked
cross-state writes), so Phase 1 closes those gaps first — cheaply, as one mechanical pass — before
four new drivers can silently inherit the same failure classes. Cost attribution proves the fan-out
pattern generalizes with the shallowest possible surface area. The database dependency phase is
the thesis-defining requirement and carries the milestone's one genuine infrastructure unknown
(can CI actually reach the database), resolved as that phase's first plan rather than a separate
phase. Service mesh reuses the same near/far hook-pair convention the database phase validates.
Security-authored cross-cutting policy comes last on purpose — it needs `Component.tags` to exist
*and* needs real drivers already populating meaningful tags, which only phases 3 and 4 provide.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Trustworthy Foundations** - Compile/apply drift becomes a CI failure, and components carry selectable shape
- [ ] **Phase 2: FinOps Cost Attribution** - A declared cost center fans out to every resource, and reviewers see cost deltas pre-merge
- [ ] **Phase 3: Database Dependency Fan-Out** - A database dependency provisions, connects, credentials, monitors, and orders itself over a network path CI can reach
- [ ] **Phase 4: Service Mesh Authorization** - A service-to-service dependency grants exactly the access that edge implies, nothing more
- [ ] **Phase 5: Security-Authored Cross-Cutting Policy** - A security engineer targets components by shape, with auditable, non-empty coverage

## Phase Details

### Phase 1: Trustworthy Foundations
**Goal**: The platform's own build and cross-state wiring are trustworthy enough to build four new stakeholder fan-outs on top of
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: FOUND-01, FOUND-02, FOUND-03, FOUND-04, FOUND-05
**Success Criteria** (what must be TRUE):
  1. CI fails the build when a fresh `protoconf compile` of the source produces output that differs from what's committed — a source edit without a local rebuild can no longer pass CI green
  2. A platform author can write a predicate over `Component.tags` and call the exported `SelectComponents` to retrieve every component in a dependency graph matching it
  3. Compiling a component whose state CI will apply, but that has no remote backend configured, fails with a message naming the missing backend — it does not silently fall back to local state
  4. Compiling a cross-state value handshake that CI's apply-ordering derivation cannot see fails with a message naming the fix, rather than producing a wrong or partial apply order
**Plans:** 3 plans

Plans:
- [ ] 01-01-PLAN.md — Drift check tracer: a hand-written workflow compiles the source and asserts the committed output matches; orphan root output trees deleted (FOUND-01)
- [ ] 01-02-PLAN.md — Component shape and graph selection: `WithLabels`, a lifted `walk_upstreams`, `SelectComponents`, facade exports, and a committed assertion probe (FOUND-02, FOUND-03)
- [ ] 01-03-PLAN.md — Compile-time state guards: redis gets a real backend, and a local backend or an unorderable cross-state read becomes a compile error naming the fix (FOUND-04, FOUND-05)

### Phase 2: FinOps Cost Attribution
**Goal**: A cost center declared once on a component propagates to its entire dependency subtree and is visible to reviewers before merge
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: COST-01, COST-02, COST-03, COST-04
**Success Criteria** (what must be TRUE):
  1. An owner declares a cost center on one component and every component in that component's dependency subtree carries it, with no second declaration required
  2. Every Terraform resource emitted by every driver — existing and new — carries the cost-attribution tags
  3. Compiling a component that emits billable resources with no cost center attributed fails with a message naming the fix
  4. A reviewer opening a pull request sees the estimated cost delta of the change
**Plans**: TBD

### Phase 3: Database Dependency Fan-Out
**Goal**: A developer declares a database dependency and receives provisioning, network access, credentials, monitoring, and correct apply ordering — without declaring any of them — over a network path CI can actually reach
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: DATA-01, DATA-02, DATA-03, DATA-04, DATA-05, DATA-06
**Success Criteria** (what must be TRUE):
  1. The CI runner's network path to the target database is an explicit, documented decision — and CI can actually reach the database — rather than an assumption discovered at the first failed apply
  2. A developer adds a database dependency to a service component and the database role and its grants are provisioned automatically
  3. The same declaration emits the network access rule permitting that service to reach the database, on both sides of the edge
  4. The service receives database credentials with no secret ever written to Terraform state or to generated config
  5. The same declaration produces database monitoring, and CI applies the database's state before the consuming service's state — with nobody declaring either
**Plans**: TBD

### Phase 4: Service Mesh Authorization
**Goal**: A developer declares a service-to-service dependency and gets exactly the access that edge implies
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: MESH-01, MESH-02
**Success Criteria** (what must be TRUE):
  1. A developer declares a dependency from service A to service B and network access is granted for exactly that edge
  2. A service that declares no dependency on another service has no network access to it
**Plans**: TBD

### Phase 5: Security-Authored Cross-Cutting Policy
**Goal**: A security engineer authors one hardening hook that applies across every component matching a declared shape, with visible, auditable coverage
**Mode:** mvp
**Depends on**: Phase 1, Phase 3, Phase 4
**Requirements**: SEC-01, SEC-02, SEC-03
**Success Criteria** (what must be TRUE):
  1. A security engineer authors a hardening hook targeting a tag selector and it applies to every matching component without editing any of those components individually
  2. Compiling a policy whose selector matches zero components fails with a message naming the fix
  3. A security engineer can open a generated artifact and see exactly which components each policy applied to
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Trustworthy Foundations | 0/3 | Planned | - |
| 2. FinOps Cost Attribution | 0/? | Not started | - |
| 3. Database Dependency Fan-Out | 0/? | Not started | - |
| 4. Service Mesh Authorization | 0/? | Not started | - |
| 5. Security-Authored Cross-Cutting Policy | 0/? | Not started | - |
