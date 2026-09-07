# Platform Engineering

## What This Is

A configuration-as-code platform where every stakeholder in a service's life — product
developers, infrastructure, SRE, security, FinOps, monitoring — meets on one artifact: the
service **component**. A developer declares what their service *is* and what it *depends on*;
the platform derives everything each other stakeholder needs from that declaration. Built on
Protoconf (Starlark over proto-typed messages) compiling to Terraform JSON and CI pipelines,
with one replaceable driver module per technology choice.

## Core Value

**A product developer declares a dependency, and every other stakeholder's concern is applied
automatically — without the developer knowing those concerns exist.** Add a database dependency
and security groups, DB user provisioning, and monitoring all follow. If a declaration does not
fan out into the consequences other teams care about, the platform has failed at the only thing
it exists to do.

## Requirements

### Validated

<!-- Shipped and working in the existing codebase. -->

- ✓ Hook-chain component model — `f(msg, next) -> msg` composed by `chain()`, type-filtered per message kind — `src/platform/core.pinc`
- ✓ Declarative dependency graph — `WithDeps` builds upstreams; `ForDownstream` lets a dependency mutate its dependants — `src/platform/core.pinc`
- ✓ Ambient context inheritance — `Inherit`-wrapped hooks propagate down the graph (failure domain today) — `src/platform/core.pinc`
- ✓ Deferred rendering — `Finally` hooks see the finished component, so derived views render against the complete picture — `src/platform/core.pinc`
- ✓ Proto-typed component schema — `platform.v1.Component`, `Objective`, `Upstreams`, `configs` map — `src/platform/v1/platform.proto`
- ✓ Terraform DSL over proto messages — `Resource`, `Data`, `Provider`, `Module`, `Output`, `link` — `src/terraform/v1/util.pinc`
- ✓ Pluggable driver architecture — one Protoconf module per replaceable choice, wired by `CONFIGSPACE`, never imported by the platform layer — `drivers/`
- ✓ State driver with five backends — S3, GCS, AzureRM, Terraform Cloud `remote`, local — `drivers/state/terraform/src/terraform.pinc`
- ✓ Cross-state value handshake — `WithRemoteOutput` pairs a publisher's `output` with each dependant's `terraform_remote_state` data source — `drivers/state/terraform/src/terraform.pinc`
- ✓ Kubernetes runtime driver — `Workload` renders Deployment + Service — `drivers/runtime/kubernetes/src/kubernetes.pinc`
- ✓ SRE-declared SLOs render monitoring automatically — `WithSLO` objectives become Grafana dashboards and alert rules in a separate monitoring state — `src/platform/monitoring.pinc`, `drivers/monitoring/grafana/src/grafana.pinc`
- ✓ Derived CI pipeline ordering — apply order recovered by matching backend state IDs against `terraform_remote_state` reads; nobody declares the DAG — `drivers/cicd/github_actions/src/github_actions.pinc`
- ✓ Credentials never in config — OIDC roles and per-job Grafana service account tokens minted in CI — `drivers/cicd/github_actions/src/github/lib.pinc`

### Active

<!-- The vision, not yet built. Hypotheses until shipped. -->

- [ ] Database dependency fans out to its full consequence set — a developer adds a DB dependency and gets network access rules, DB user/role provisioning, credential delivery, and monitoring without naming any of them
- [ ] Service-to-service dependency configures service mesh access automatically from the declared edge
- [ ] Security stakeholders can inject hardening hooks that apply across all relevant components, without editing each component
- [ ] Component declarations carry enough shape for cross-cutting policy to select the right targets ("all components with a public ingress", "all components with a datastore dependency")
- [ ] FinOps has a seat — cost attribution and visibility derived from the same component declarations
- [ ] The platform's own foundations are trustworthy enough to build these on — the divergent `util.pinc` fork resolved, the root build working or removed, missing backends a compile error rather than silent local state

### Out of Scope

- Application runtime or service code — this platform emits configuration; it does not run or host services
- A unified abstraction spanning ECS and Kubernetes workloads — an interface wide enough for both is a union, which is neither; one driver per runtime instead (documented in `drivers/runtime/kubernetes/src/kubernetes.pinc`)
- Organisation-specific values inside drivers (bucket names, regions, datasource uids) — those are call-site arguments; drivers are the reusable half
- Per-component pipeline declarations — apply order is already written down in backend keys and remote-state reads; restating it lets the two drift
- Replacing Terraform as the execution engine — Terraform applies what the platform emits

## Context

**Existing foundation.** This is a brownfield project with a working reference stack. The core
hook/component model, the Terraform DSL, and four drivers (runtime/kubernetes, runtime/ecs,
state/terraform, monitoring/grafana, cicd/github_actions) already exist and compile.
`test/src/core_test.mpconf` is the live reference: it declares components, SLOs, and a backend,
and `make -C test` compiles it to `test/outputs/**`. Full map in `.planning/codebase/`.

**The pattern that already proves the thesis.** SLOs are the working proof of the vision: an SRE
adds `WithSLO(...)` to a component and Grafana dashboards plus alert rules appear downstream,
in their own Terraform state, with no dashboard written by hand. The Active requirements are
the same mechanism extended to more stakeholders — dependencies fanning out to security,
provisioning, and mesh configuration the way objectives already fan out to monitoring.

**Known foundation issues** (detail in `.planning/codebase/CONCERNS.md`):
- `src/terraform/v1/util.pinc` and `test/src/terraform/v1/util.pinc` are a 161-line fork, and
  only the *unimported* copy has the fixes — bug fixes land where nobody loads them
- The root build is decorative: no root `CONFIGSPACE`/lock, and `src/` cannot compile standalone
- `redis/infra` silently renders `backend: {local: {}}` from a missing `BACKEND` argument, so CI
  discards its state every apply
- `test/protoconf.lock` commits absolute local paths (`file:///Users/smintz/...`)
- CI never runs `protoconf compile` — it plans and applies the *committed* `test/outputs/`, so a
  source edit without `make -C test` yields a green build against stale generated Terraform
- Zero schema-level validation: no `buf.validate.field` annotations, no `.proto-validator` files;
  all cross-field enforcement is ad-hoc `fail()` inside drivers

## Constraints

- **Tech stack**: Protoconf (Starlark + proto) compiling to Terraform JSON — the type system is protobuf, and every value the platform produces must be expressible as a proto message
- **Tech stack**: Terraform 1.9.8 in CI, applied per state directory on GitHub Actions runners
- **Architecture**: The module graph must stay acyclic — drivers load `@platform`, the platform layer loads no driver, and drivers never load each other
- **Architecture**: Hook ordering is load-bearing — main config mutates before the component chain; inherited hooks run before local ones
- **Security**: Credentials never appear in configuration — CI mints them (OIDC, short-lived tokens); backends carry location only
- **Failure mode**: Fail at compile time in Starlark with a message naming the fix; return `None` rather than a wrong answer

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Middleware hook chain over a proto `Component` as the core abstraction | Every stakeholder contributes the same shape of thing — a mutation — so concerns compose without knowing about each other | ✓ Good — proven by SLOs fanning out to monitoring |
| One Protoconf module per driver, wired by `CONFIGSPACE` | Keeps the dependency arrows one-way and makes a technology choice replaceable rather than forked | ✓ Good |
| Derive CI apply order from backend state IDs rather than declaring it | The order is already encoded in backend keys and remote-state reads; declaring it a second time invites drift | — Pending |
| Output is data, not templates — Starlark returns proto messages that `protoconf compile` serializes | Type-checked at compile time, and the generated artifact is inspectable | ✓ Good |
| Separate Terraform state for monitoring vs infra | A dashboard change should not be able to touch a Deployment | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-09-07 after initialization*
