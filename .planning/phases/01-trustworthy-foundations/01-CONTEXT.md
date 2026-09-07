# Phase 1: Trustworthy Foundations - Context

**Gathered:** 2026-09-07
**Status:** Ready for planning

<domain>
## Phase Boundary

The platform's own build and cross-state wiring become trustworthy enough to build four new
stakeholder fan-outs (FinOps, database, mesh, security) on top of. Three things ship:

1. A CI check that fails when committed generated output no longer matches a fresh compile
2. Components carry declared, selectable shape, and a platform author can retrieve every
   component in a graph matching a predicate
3. Two classes of silent misconfiguration — a CI-applied state with no remote backend, and a
   cross-state handshake CI's ordering derivation cannot see — become compile errors

Not in this phase: any new driver, any new stakeholder capability, any policy content. This
phase makes the ground solid; phases 2-5 build on it.

</domain>

<decisions>
## Implementation Decisions

### Drift Check (FOUND-01)

- **D-01:** The drift check is a **hand-written, standalone GitHub Actions workflow**, not a job
  emitted by the `github_actions` driver into the generated pipeline.
  *Rationale:* the artifact being checked IS the generated pipeline. A drift check that is
  itself generated can be silently omitted by the very staleness it exists to catch — a stale
  `.github/workflows/terraform.yaml` would ship without its own guard. The checker must not be
  the checked. This is the one place in the repo where hand-written CI is correct.
  — **Reversibility:** reversible — one workflow file.

- **D-02:** The check runs `cd test && make test`, then `git diff --exit-code` over the three
  trees that command writes: `test/materialized_config/`, `test/outputs/`, and the repo-root
  `.github/workflows/terraform.yaml` that `make workflows` copies into place.
  *Rationale:* `make test` is already the repo's real build (`test/Makefile`); the drift check
  is that build plus an assertion. All three trees must be covered — the workflow copy is a
  separate write and can go stale independently of `test/outputs/`.

- **D-03:** Trigger on **source paths**, not on `test/outputs/**`. The existing generated
  pipeline triggers on `paths: [test/outputs/core_test/**]`, which by construction cannot fire
  for the exact failure being guarded against — a source edit with no regenerated output.
  Trigger on `test/src/**`, `src/**`, `drivers/**`, `test/CONFIGSPACE`, `test/protoconf.lock`.
  *Rationale:* a guard that cannot fire on its own failure mode is decoration.

- **D-04:** The workflow needs `protoconf` on the runner. Pin the version explicitly rather than
  installing latest — an unpinned compiler makes every drift result a moving target.

### Drift Check Scope (FOUND-01)

- **D-05:** Delete the orphan root `outputs/` and `materialized_config/` trees as part of this
  phase. They describe an `aurora-user-api-task` component that exists in no `.mpconf`
  (`.planning/codebase/CONCERNS.md`), and the root build that would regenerate them cannot run —
  there is no root `CONFIGSPACE` or `protoconf.lock`, and `src/terraform/v1/util.pinc` loads a
  `terraform.proto` that exists only under `test/src/`.
  *Rationale:* a drift check must have a defined scope. Two output trees where only one is
  reachable from any source makes "is the output current?" unanswerable. `git rm -r` them;
  history keeps them.
  — **Reversibility:** reversible — recoverable from git history.

- **D-06:** Leave the root `Makefile` and `providers.tf` alone in this phase. They are also
  broken/orphaned, but nothing in FOUND-01..05 depends on them and touching them widens the diff.
  Recorded in Deferred.

### Component Shape (FOUND-02)

- **D-07:** **Reuse the existing `Component.Metadata.labels` field. Do NOT add a new
  `Component.tags` field.**
  *Rationale:* `src/platform/v1/platform.proto` already declares
  `Component.Metadata { repeated string tags = 1; map<string,string> labels = 2; }`, and a grep
  across `src/platform/*.pinc`, `drivers/*/*/src/*.pinc`, and `test/src/core_test.mpconf`
  confirms **neither field is written or read by any Starlark in the repo** — the only `metadata`
  hits are the Kubernetes provider's own resource metadata. The research SUMMARY.md proposed
  adding `map<string,string> tags` to `Component`; that field already exists under a different
  name and is free. Adding a second one creates two overlapping shape vocabularies, which is
  precisely what makes a selector unauditable.
  — **Reversibility:** costly — once phases 2-5 write cost centers into this field and select
  policies against it, changing the field means touching every driver and every call site that
  writes or selects. Cheap to change now, expensive after Phase 2.

- **D-08:** `Metadata.tags` (the `repeated string` one) stays unused. One shape vocabulary,
  `labels`, keyed and valued. A bare-tag set and a key/value map answering the same question is
  the ambiguity that makes "which components did this policy match?" unanswerable.

- **D-09:** No `WithLabels` hook is required by this phase's requirements, but if the planner
  adds one it must be an ordinary `component_filter` hook following the existing `WithX(...)`
  factory convention (`.planning/codebase/CONVENTIONS.md`), not a new marker kind.

### SelectComponents (FOUND-03)

- **D-10:** Factor the existing `walk_upstreams` closure out of `GetConfigs`
  (`src/platform/core.pinc:205-210`) to module level and build `SelectComponents` on it. Do not
  write a second traversal.
  *Rationale:* that traversal is the one already proven correct against the reference stack.
  A second one is a second thing that can disagree with `GetConfigs` about what the graph is.

- **D-11:** Signature `SelectComponents(root, predicate)` returning a **list**, in the same
  deterministic post-order the existing traversal produces, **de-duplicated by component
  identity**.
  *Rationale:* the current traversal does not de-duplicate. `GetConfigs` survives that because
  it keys results by `"<domain>/<name>/<config>"` so a diamond dependency's repeats collapse
  silently. A selector has no such key — a component reached by two paths would be returned
  twice and a policy hook applied to it twice. De-duplicate in `SelectComponents`.

- **D-12:** **Do not change `GetConfigs`' output.** Factoring the traversal out must leave
  `GetConfigs` byte-identical in behavior. The verification for this is an empty `git diff` on
  `test/materialized_config/` and `test/outputs/` after `cd test && make test` — except for the
  one deliberate change in D-14.
  — **Reversibility:** reversible.

- **D-13:** Export `SelectComponents` through the `platform` facade
  (`src/platform/platform.pinc`) alongside the existing exports, so call sites reach it the same
  way they reach everything else. The facade loads `core.pinc`; the acyclic-module-graph
  constraint is preserved.

### Compile-Time Enforcement (FOUND-04, FOUND-05)

- **D-14:** Enforce both checks **inside the CI driver's `TerraformPipeline`**
  (`drivers/cicd/github_actions/src/github_actions.pinc`), next to the existing job-id collision
  `fail()` at line 603 — **not** as a `.proto-validator` and not as a `fail()` in the state driver.
  *Rationale:* `.planning/codebase/CONVENTIONS.md` does say to prefer a validator over a driver
  `fail()`, and that guidance is right for anything expressible about a `Component` in isolation.
  It does not apply here: both FOUND-04 and FOUND-05 are assertions about the relationship
  between a config and *the pipeline that will apply it*. A validator bound to `Component` cannot
  see the pipeline. `TerraformPipeline` is the only place that knows which configs CI applies and
  how apply order was derived, so it is the only place the check can be true.

- **D-15:** FOUND-04 fires when a config the pipeline will emit an **apply** job for renders a
  `local` backend (or a backend `_backend_state_id` returns `None` for). Message names the fix:
  the component and the missing `BACKEND` argument to `WithState`.
  *Consequence the planner must handle:* this immediately breaks the reference stack.
  `test/src/core_test.mpconf:50` builds `RedisComponent` with
  `WithState(lambda component: Workload(...))` and no `BACKEND`, which is exactly the bug
  (`test/outputs/core_test/us-east-1/redis/infra/main.tf.json` renders `"backend": {"local": {}}`,
  so CI discards Redis state on every apply). The same plan must pass `BACKEND` at that call site.

- **D-16:** That fix produces a **deliberate, expected** golden-file diff on
  `test/outputs/core_test/us-east-1/redis/infra/main.tf.json` (local → S3 backend), and a
  consequent change to the generated pipeline's job ordering, since a real backend gives Redis a
  state id that the ordering derivation can now match. This is the one place in Phase 1 where a
  non-empty golden diff is correct. Everything else must diff empty.

- **D-17:** FOUND-05 fires when a config declares a `terraform_remote_state` data source whose
  state id matches no other config's backend state id — a cross-state read pointing at a state
  this pipeline does not produce. Message names the fix. This is the guard that makes the near/far
  hook-pair convention enforceable for the DB and mesh drivers in phases 3-5.

- **D-18:** Both messages follow the project's stated error convention: `fail()` at compile time
  naming the fix, never a silent fallback and never a wrong answer
  (`.planning/codebase/ARCHITECTURE.md`, Error Handling).

### Claude's Discretion

Auto mode selected the recommended option for every area. The planner has latitude on: exact
workflow YAML structure and action versions for the drift check; the precise `SelectComponents`
predicate calling convention (component message vs. wrapper); internal helper naming; whether
`walk_upstreams` keeps its `next`-callback shape or becomes a plain generator-style collector
once factored out.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope and requirements
- `.planning/ROADMAP.md` — Phase 1 goal, mode (mvp), and its 4 success criteria
- `.planning/REQUIREMENTS.md` — FOUND-01 through FOUND-05, the 5 requirements mapped to this phase
- `.planning/PROJECT.md` — Core Value, constraints (acyclic module graph, hook ordering, compile-time failure convention)

### Source files this phase modifies
- `src/platform/v1/platform.proto` — `Component.Metadata.labels` at the `Metadata` message; the field D-07 reuses
- `src/platform/core.pinc` — `GetConfigs` and the nested `walk_upstreams` closure (lines ~180-215) that D-10 factors out; `CONFIG_TYPES` at line 131
- `src/platform/platform.pinc` — the facade D-13 exports `SelectComponents` through
- `drivers/cicd/github_actions/src/github_actions.pinc` — `TerraformPipeline`, `_backend_state_id`, `_state_id`, and the existing job-id collision `fail()` at line 603 where D-14 adds enforcement
- `drivers/state/terraform/src/terraform.pinc` — `_backend`, `LocalBackend`, `DEFAULT_BACKEND`, `WithState`, `WithRemoteOutput`; the backend vocabulary FOUND-04/05 reason about
- `test/src/core_test.mpconf` — line ~50 (`RedisComponent`, missing `BACKEND`) that D-15 fixes; line ~81 (`ApiTaskComponent`) shows the correct form
- `test/Makefile` — the `test` and `workflows` targets D-02's check invokes

### Codebase map (read before planning)
- `.planning/codebase/ARCHITECTURE.md` — hook/marker vocabulary, data flow, error handling convention, architectural constraints
- `.planning/codebase/TESTING.md` — **critical for this phase.** The golden-file verification loop, what `make test` does, why there is no unit-test framework, and the "no CI job runs protoconf compile" gap FOUND-01 closes
- `.planning/codebase/CONVENTIONS.md` — naming (`WithX`, `PascalCase`, `snake_case`, `_private`, `UPPER_SNAKE`), the hook pattern, and the validation-idiom guidance D-14 deliberately departs from (with reason)
- `.planning/codebase/CONCERNS.md` — the redis local-backend bug, the orphan root output trees, the util.pinc fork, and the compile/apply drift gap this phase closes
- `.planning/codebase/STACK.md` — protoconf/terraform versions, module wiring via `test/CONFIGSPACE`

### Research
- `.planning/research/SUMMARY.md` §"Phase 1: Foundation" and §"Critical Pitfalls" items 2 and 4 — note that its proposal to add a new `Component.tags` field is **superseded by D-07**; the field already exists as `Metadata.labels`
- `.planning/research/PITFALLS.md` — compile/apply drift and cross-state-write pitfalls in detail
- `.planning/research/ARCHITECTURE.md` — the selector-vs-action separation pattern D-07/D-11 implement

### Project skill
- `.claude/skills/protoconf-dev/SKILL.md` — Starlark/proto/compile mechanics. Invoke before writing any `.pinc` or `.proto` change in this phase.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`Component.Metadata.labels`** (`src/platform/v1/platform.proto`): `map<string,string>`, already
  in the schema, written by nothing. FOUND-02 is populating an existing field, not adding one.
- **`walk_upstreams`** (`src/platform/core.pinc:205`): the graph traversal `GetConfigs` already
  relies on, proven against the reference stack. `SelectComponents` is a second consumer of it,
  not a second traversal.
- **The job-id collision `fail()`** (`drivers/cicd/github_actions/src/github_actions.pinc:603`):
  precedent for compile-time enforcement inside `TerraformPipeline` — FOUND-04/05 sit beside it.
- **`_backend_state_id` / `_state_id`** (same file): already render a backend and a
  `terraform_remote_state` to a comparable URI. FOUND-05's "does this read point at a state we
  produce?" check is a use of machinery that exists, not new logic.
- **`test/Makefile`**: `make test` already is the build. The drift check is that plus
  `git diff --exit-code`.

### Established Patterns
- **Golden-file verification** (`.planning/codebase/TESTING.md`): correctness is an empty
  `git diff` on `test/materialized_config/` and `test/outputs/` after recompiling. Every task in
  this phase is verifiable that way — which is also why D-16's deliberate diff must be called out
  explicitly, or it reads as a regression.
- **`fail()` at compile time naming the fix**, never a silent fallback (`.planning/codebase/ARCHITECTURE.md`).
  `LocalBackend.config_for` already refuses to guess; FOUND-04 extends the same stance.
- **`WithX(...)` hook factories, `_leading_underscore` module-private helpers, `UPPER_SNAKE`
  constants** (`.planning/codebase/CONVENTIONS.md`).
- **Acyclic module graph**: `platform.pinc` loads `core.pinc`; `core.pinc` must not load back.
  D-13's export respects this.

### Integration Points
- `src/platform/platform.pinc` — where `SelectComponents` becomes reachable from call sites
- `drivers/cicd/github_actions/src/github_actions.pinc` `TerraformPipeline` — where FOUND-04/05 fire
- `test/src/core_test.mpconf` — the reference stack that must still compile after FOUND-04 lands,
  which is why the redis `BACKEND` fix is in this phase and not deferred
- `.github/workflows/` — gains one new hand-written file; the existing `terraform.yaml` there stays
  generated and must not be hand-edited

</code_context>

<specifics>
## Specific Ideas

- The drift check's failure message should tell the contributor exactly what to run:
  `cd test && make test`, then commit the result. A drift failure that only says "output differs"
  makes every contributor rediscover the fix.
- FOUND-04's message should name the component and the argument (`BACKEND` to `WithState`), not
  just report "local backend". The existing job-id collision `fail()` is the tone to match.
- Redis is the live instance of the FOUND-04 bug. Fixing it in the same plan that adds the check
  is what proves the check works — the guard and its first catch land together.

</specifics>

<deferred>
## Deferred Ideas

These came up in scouting or research and are real, but are outside FOUND-01..05:

- **The `util.pinc` fork** — `src/terraform/v1/util.pinc` and `test/src/terraform/v1/util.pinc`
  have diverged by 161 lines, and only the *unimported* copy has the fixes (empty-hook-list-safe
  `Chain`, provider dedup at insertion). Drivers resolve `@platform//terraform/v1/util.pinc` to the
  root copy, so bug fixes land where nobody loads them. Substantial; deserves its own phase or a
  scoped `/gsd-quick`.
- **`Walk` iterates the wrong field** — `src/terraform/v1/util.pinc:161` iterates
  `component.upstreams` directly rather than `component.upstreams.components`, so
  `GenerateTerraformConfigs` visits no dependency. Unused today (the live stack uses `GetConfigs`),
  which is why it is not blocking, but it is a broken duplicate of the same job.
- **Root build is decorative** — no root `CONFIGSPACE`/`protoconf.lock`, and `src/` cannot compile
  standalone. Either make it work or delete the root `Makefile` targets and document `test/` as
  the entry point. D-06 leaves it alone this phase.
- **Root `providers.tf` is orphaned** — bare provider stubs with no version constraint at a path
  that is not a Terraform working directory.
- **`test/protoconf.lock` commits absolute local paths** (`file:///Users/smintz/...`), leaking a
  username and breaking any checkout elsewhere.
- **S3 backend has no state locking** — no `dynamodb_table`/`use_lockfile`, while the generated
  workflow passes a `-lock-timeout` that does nothing. Research flags that this compounds as
  phases 3-5 add new states.
- **Schema-level validation** — `.planning/codebase/CONVENTIONS.md` names the natural first
  candidates (`buf.validate.field` on `Objective.Query.min`/`max` and `Component.name`; a
  `.proto-validator` for cross-field rules like `min <= max`). Genuinely valuable and adjacent to
  this phase's spirit, but not required by FOUND-01..05.
- **`TODO(smintz)` in `Component.Objective.Check`** (`src/platform/v1/platform.proto`) — an
  unspecified field in the schema every driver depends on.

</deferred>

---

*Phase: 1-Trustworthy Foundations*
*Context gathered: 2026-09-07*
