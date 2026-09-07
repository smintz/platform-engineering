<!-- refreshed: 2026-09-07 -->
# Architecture

**Analysis Date:** 2026-09-07

## System Overview

```text
┌─────────────────────────────────────────────────────────────┐
│  Call site (one file per config space)                       │
│  `test/src/core_test.mpconf` — components, SLOs, main()      │
└────────┬────────────────────────────────────────────────────┘
         │ loads @platform + @<driver> via CONFIGSPACE
         ▼
┌──────────────────┬──────────────────┬───────────────────────┐
│  platform facade │  hook core       │  monitoring hooks     │
│ `src/platform/`  │ `src/platform/`  │ `src/platform/`       │
│ `platform.pinc`  │ `core.pinc`      │ `monitoring.pinc`     │
└────────┬─────────┴────────┬─────────┴──────────┬────────────┘
         │                  │                     │
         ▼                  ▼                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Drivers (one module per replaceable choice)                 │
│  runtime  `drivers/runtime/{kubernetes,ecs}/src/*.pinc`      │
│  state    `drivers/state/terraform/src/terraform.pinc`       │
│  monitor  `drivers/monitoring/grafana/src/grafana.pinc`      │
│  cicd     `drivers/cicd/github_actions/src/github_actions.pinc`│
└────────┬────────────────────────────────────────────────────┘
         │ all write terraform.v1.Terraform messages into
         │ Component.configs (map<string, google.protobuf.Any>)
         ▼
┌─────────────────────────────────────────────────────────────┐
│  platform.GetConfigs()  `src/platform/core.pinc`             │
│  walks upstreams, unpacks Any, keys "<domain>/<name>/<file>" │
└────────┬────────────────────────────────────────────────────┘
         │ main() returns {path: message}
         ▼
┌─────────────────────────────────────────────────────────────┐
│  `protoconf compile`                                         │
│  `materialized_config/**/*.materialized_JSON`  (typed Any)   │
│  `outputs/**` (`main.tf.json`, `.github/workflows/*.yaml`)   │
└────────┬────────────────────────────────────────────────────┘
         ▼
┌─────────────────────────────────────────────────────────────┐
│  terraform apply per output directory; `providers.tf` at root│
│  CI does it: `test/outputs/core_test/.github/workflows/`     │
└─────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| `platform` facade | Single load line exposing every hook/marker; drivers deliberately excluded | `src/platform/platform.pinc` |
| Hook core | `chain`, `flatten`, `message_filter`, `Component`, markers, `GetConfigs` | `src/platform/core.pinc` |
| Monitoring vocabulary | `WithSLO`, `WithDiagnostic`, `WithMonitoring`, separate monitoring state | `src/platform/monitoring.pinc` |
| Component schema | `platform.v1.Component`, `Objective`, `Upstreams`, `configs` map | `src/platform/v1/platform.proto` |
| Terraform DSL | `Terraform`, `Resource`, `Data`, `Provider`, `Module`, `Output`, `link` | `src/terraform/v1/util.pinc` |
| State driver | Backends (`S3`/`GCS`/`AzureRM`/`Remote`/`Local`), `WithState`, `WithRemoteOutput` | `drivers/state/terraform/src/terraform.pinc` |
| Kubernetes runtime driver | `Workload` (Deployment + Service), `KubeConfig`, `WithContainerEnv` | `drivers/runtime/kubernetes/src/kubernetes.pinc` |
| ECS runtime driver | `TaskSpec` parked as working state, `WithContainer`, `WithTaskEnv` | `drivers/runtime/ecs/src/ecs.pinc`, `drivers/runtime/ecs/src/lib/ecs/ecs.pinc` |
| Grafana monitoring driver | Renders dashboard + alert rules from declared objectives | `drivers/monitoring/grafana/src/grafana.pinc`, `drivers/monitoring/grafana/src/grafana/alerts.pinc` |
| GitHub Actions CI driver | Derives plan/apply pipeline and its ordering from the config map | `drivers/cicd/github_actions/src/github_actions.pinc`, `drivers/cicd/github_actions/src/github/lib.pinc` |

## Pattern Overview

**Overall:** Middleware hook chain over a protobuf `Component`, with pluggable drivers and a compile-time materialization step.

**Key Characteristics:**
- Every mutation is a hook `f(msg, next) -> msg` composed by `chain()` (`src/platform/core.pinc`).
- Hooks are type-filtered: `component_filter` runs only on `platform.v1.Component`, `terraform_filter` only on `terraform.v1.Terraform`. One hook list is passed through both message types.
- Drivers are separate Protoconf modules wired by `CONFIGSPACE`, never imported by the platform layer — dependency arrows point one way, call site → platform → nothing.
- Output is data, not templates: Starlark returns proto messages, `protoconf compile` serializes them to `outputs/`.

## Layers

**Call site (config space):**
- Purpose: Declare components, their SLOs, backend, and the pipeline
- Location: `test/src/core_test.mpconf` (entry), `test/CONFIGSPACE` (module wiring)
- Contains: `Component` factory functions and `main()`
- Depends on: `@platform`, `@<driver>` labels
- Used by: `protoconf compile`

**Platform core:**
- Purpose: Hook plumbing, component construction, config collection
- Location: `src/platform/`
- Contains: `core.pinc`, `monitoring.pinc`, `platform.pinc`, `v1/platform.proto`
- Depends on: `src/terraform/v1/util.pinc`, `any.star`
- Used by: call sites and every driver

**Terraform DSL:**
- Purpose: Build `terraform.v1.Terraform` messages and resource references
- Location: `src/terraform/v1/util.pinc`, `src/terraform/v1/meta.proto`
- Used by: all drivers via `load("@platform//terraform/v1/util.pinc", tf = "util")`

**Drivers:**
- Purpose: One replaceable technology choice each (runtime / state / monitoring / cicd)
- Location: `drivers/<kind>/<name>/src/`
- Depends on: `@platform` plus its own generated provider protos
- Used by: call sites only

## Data Flow

### Component → Terraform file

1. Call site calls `platform.Component(slug, *hooks)` (`src/platform/core.pinc`).
2. `Component` splits markers (`WithDeps`, `ForDownstream`, `Finally`, `Inherit`) out of the hook list — markers are `module` values, not functions.
3. Inherited hooks run first (ambient context: failure domain), then local hooks.
4. `mutate_config(component, MAIN_CONFIG, *hooks)` runs the same hook list against a `terraform.v1.Terraform` message — only Terraform-typed hooks fire.
5. `chain(component, *hooks)` runs the same list against the Component message — only component-typed hooks fire.
6. Dependencies from `WithDeps` are built with `Inherit(*inherited)`, appended to `component.upstreams`, then `dep.RunForDownstream(component)` fires the dep's `ForDownstream` hooks against the downstream component.
7. `Finally` hooks run last, seeing the finished component (this is where `WithGrafanaDashboard` renders, `drivers/monitoring/grafana/src/grafana.pinc:411`).
8. `platform.GetConfigs(component.msg)` walks upstreams depth-first, skips config keys whose `type_url` is not in `CONFIG_TYPES`, skips configs equal to their empty prototype, and keys survivors `"<domain>/<name>/<config key>"`.
9. `main()` returns that map plus `.github/workflows/terraform.yaml` from `actions.TerraformPipeline(configs, ...)`.
10. `protoconf compile` writes `materialized_config/<path>.materialized_JSON` (Any-wrapped, with `protoFile`) and, with `-process-templates`, plain `outputs/<path>`.

### Cross-state value handshake

1. `WithRemoteOutput(name, value, backend)` returns a pair of hooks (`drivers/state/terraform/src/terraform.pinc`).
2. The near half adds `output "name"` to the publisher's config and records its domain/name in a closed-over cell.
3. The far half, wrapped in `ForDownstream`, adds a `terraform_remote_state` data source to each dependant.
4. The dependant reads it with `RemoteOutput(component, output)`.

### Pipeline ordering

1. `_backend_state_id(config)` renders a config's backend block to a URI (`s3://bucket/key`, etc.).
2. `_remote_state_id(remote_state)` renders a `terraform_remote_state` data source to the same URI shape.
3. Matching the two recovers the apply-order DAG without anyone declaring it (`drivers/cicd/github_actions/src/github_actions.pinc`).

**State Management:**
- Component-owned state lives in `Component.configs` as `google.protobuf.Any`.
- Two config kinds share the map: renderable configs (registered in `CONFIG_TYPES`) and driver scratch space parked on the component (`TASK_SPEC = "runtime/ecs/task_spec"`), which `GetConfigs` deliberately drops.
- Terraform state itself: one state per config key; `infra/main.tf.json` and `monitoring/main.tf.json` are separate states on purpose (`src/platform/monitoring.pinc`).

## Key Abstractions

**Hook (`f(msg, next) -> msg`):**
- Purpose: A single composable mutation
- Examples: `src/platform/core.pinc` (`WithDescription`), `drivers/runtime/kubernetes/src/kubernetes.pinc` (`WithContainerEnv`)
- Pattern: Middleware chain with explicit `next`

**Marker (`module(...)` with `kind`):**
- Purpose: Instructions `Component` acts on itself, because they cannot be expressed as "mutate this message"
- Kinds: `deps`, `downstream`, `inherit`, `finalize`
- Location: `src/platform/core.pinc`

**Backend struct:**
- Purpose: One description of a state location, split into writer (`state`) and reader (`remote`) so the two cannot disagree
- Location: `drivers/state/terraform/src/terraform.pinc` (`_backend`)

**Component factory:**
- Purpose: `def MyComponent(*hooks)` — uninstantiated so `WithDeps` can build it with inherited hooks
- Examples: `test/src/core_test.mpconf` (`RedisComponent`, `ApiTaskComponent`)

## Entry Points

**`test/src/core_test.mpconf` → `main()`:**
- Triggers: `protoconf compile .` from `test/`
- Responsibilities: Build the component tree, collect configs, append the CI workflow

**`Makefile` (root):**
- `make build` → `protoconf fmt -w` then `protoconf compile -process-templates .`

**`test/Makefile`:**
- `make test` → `protoconf mod tidy`, `protoconf compile .`, then copies the generated workflow to `../.github/workflows/` (GitHub reads nowhere else)

**`providers.tf` (root):**
- Terraform provider stubs (`kubernetes`, `grafana`) for running applies from the repo root

## Architectural Constraints

- **Module graph is acyclic by construction:** `platform.pinc` loads `core.pinc` and `monitoring.pinc`, so neither may load it back (stated in `src/platform/platform.pinc`).
- **Drivers never load each other:** one module per driver in `test/CONFIGSPACE`; a second monitoring or CI driver is a sibling repo, not a branch inside the first.
- **Hook ordering is load-bearing:** main config is mutated *before* the component chain so a dep's `ForDownstream` writes are not overwritten by `TerraformConfig`; inherited hooks run before local ones.
- **Config unpacking assumes Terraform:** `mutate_config` re-opens an existing config only as `tf.Terraform()`; a non-Terraform config can be set but not re-opened (`ponytail:` note in `src/platform/core.pinc`).
- **proto2 presence:** the Kubernetes provider proto is proto2, so assigning `""` to `config_context` makes it *present and empty*; `KubeConfig` only sets it when asked (`drivers/runtime/kubernetes/src/kubernetes.pinc`).
- **`any.pack` duplicates repeated providers:** worked around by de-duplicating in `GenerateTerraformConfigs` (`src/terraform/v1/util.pinc`).

## Anti-Patterns

### Rendering a view mid-chain

**What happens:** A hook that renders something derived from the component (a dashboard, an ECS task) is placed in the ordinary hook list.
**Why it's wrong:** It only sees the half of the component built before it — dependency contributions arrive after the local chain.
**Do this instead:** Wrap it in `platform.Finally(...)`, as `WithGrafanaDashboard` does (`drivers/monitoring/grafana/src/grafana.pinc:411`) and as `ecs.pinc` documents.

### A wide "runtime" interface over ECS and Kubernetes

**What happens:** Abstracting both runtimes behind one workload interface.
**Why it's wrong:** An ECS task is a task definition + service + IAM roles; a Kubernetes workload is a Deployment + Service addressed by DNS. An interface wide enough for both is a union, which is the same as neither (`drivers/runtime/kubernetes/src/kubernetes.pinc`).
**Do this instead:** One driver file per runtime under `drivers/runtime/<name>/src/`.

### Baking organisation specifics into a driver

**What happens:** A bucket name, region, or datasource uid written into a driver.
**Why it's wrong:** Drivers are the reusable half; those values differ per organisation while the wiring does not.
**Do this instead:** Take them as arguments at the call site — `BACKEND` and `DATASOURCES` in `test/src/core_test.mpconf`; Grafana looks datasources up by name and lets Terraform substitute the uid.

### Declaring a pipeline per component

**What happens:** A component states its own CI jobs or apply order.
**Why it's wrong:** The order is already written down in backend keys and `terraform_remote_state` config; restating it lets the two drift.
**Do this instead:** Pass the `GetConfigs()` map to `actions.TerraformPipeline` and let ordering be derived.

## Error Handling

**Strategy:** Fail at compile time, in Starlark, with a message naming the fix.

**Patterns:**
- `fail()` when a configuration cannot be honoured — `LocalBackend.config_for` refuses to guess a path for a cross-state read (`drivers/state/terraform/src/terraform.pinc`).
- Return `None` rather than a wrong answer: `_backend_state_id` returns `None` for an unrecognised backend, and a `None` never matches, costing an edge instead of producing a wrong one.
- Skip rather than emit: `GetConfigs` drops configs identical to their empty prototype so a hooks-only component emits no empty file.

## Cross-Cutting Concerns

**Logging:** None in Starlark; `protoconf compile` output only.
**Validation:** Proto schemas are the type system; no `.proto-validator` files present. `protoconf fmt -w` runs before every build (`Makefile`).
**Authentication:** Never in config — OIDC credentials and a per-job Grafana service account token are minted in CI (`actions.GrafanaServiceAccountToken` in `test/src/core_test.mpconf`); backends carry location only.
**Failure domains:** `WithFailureDomain` is `Inherit`-wrapped, so a dependency shares its dependant's blast radius and the domain prefixes every emitted path.

---

*Architecture analysis: 2026-09-07*
