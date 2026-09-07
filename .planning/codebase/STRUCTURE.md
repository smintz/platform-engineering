# Codebase Structure

**Analysis Date:** 2026-09-07

## Directory Layout

```
platform-engineering/
├── src/                      # The @platform module — reusable hook core + Terraform DSL
│   ├── platform/
│   │   ├── platform.pinc     # Facade struct; the one load line a call site needs
│   │   ├── core.pinc         # chain/filters/Component/markers/GetConfigs
│   │   ├── monitoring.pinc   # WithSLO, WithDiagnostic, WithMonitoring
│   │   └── v1/platform.proto # platform.v1.Component schema
│   ├── terraform/v1/
│   │   ├── util.pinc         # Terraform message builders (Resource, Data, Module, ...)
│   │   └── meta.proto        # MetaFields, Lifecycle
│   └── protoconf_terraform/config/v1/config.proto  # plugin + subscription config
├── drivers/                  # One Protoconf module per replaceable technology choice
│   ├── cicd/github_actions/src/
│   ├── monitoring/grafana/src/
│   ├── runtime/ecs/src/
│   ├── runtime/kubernetes/src/
│   └── state/terraform/src/
├── test/                     # The live config space (call site + compiled artifacts)
│   ├── CONFIGSPACE           # remote_repo() wiring for @platform and each driver
│   ├── protoconf.lock        # resolved module revisions + descriptor set sums
│   ├── Makefile              # compile, then install the workflow to ../.github/workflows
│   ├── src/core_test.mpconf  # entry point: components, SLOs, main()
│   ├── src/terraform/**      # generated provider schemas (grafana v4, kubernetes v3)
│   ├── materialized_config/  # compiler output, Any-typed JSON
│   └── outputs/              # rendered artifacts: main.tf.json, workflow yaml
├── providers.tf              # root Terraform provider stubs (kubernetes, grafana)
├── Makefile                  # fmt → compile -process-templates .
└── scripts/                  # Node CLI tooling (changesets, codegen, lint helpers)
```

## Directory Purposes

**`src/`:**
- Purpose: The `@platform` module — everything reusable that is not a technology choice
- Contains: `.pinc` Starlark libraries and `.proto` schemas
- Key files: `src/platform/core.pinc`, `src/platform/platform.pinc`, `src/terraform/v1/util.pinc`

**`drivers/<kind>/<name>/src/`:**
- Purpose: One driver module per replaceable choice; kinds are `cicd`, `monitoring`, `runtime`, `state`
- Contains: the driver `.pinc` at `src/` root, helper `.pinc` under a subpackage, driver-owned `.proto` schemas
- Key files: `drivers/state/terraform/src/terraform.pinc`, `drivers/runtime/kubernetes/src/kubernetes.pinc`, `drivers/monitoring/grafana/src/grafana.pinc`, `drivers/cicd/github_actions/src/github_actions.pinc`
- Note: each driver has a `src/v1/dummy.proto` or equivalent so the module always has a descriptor set

**`test/`:**
- Purpose: The config space that actually compiles — an example stack (`api-task` + `redis` on Kubernetes, Grafana dashboards, S3 state, GitHub Actions pipeline)
- Contains: `CONFIGSPACE`, `protoconf.lock`, `src/core_test.mpconf`, generated provider protos, and both output trees

**`test/src/terraform/{grafana,kubernetes}/`:**
- Purpose: Provider schemas generated from the Terraform provider, split `provider/`, `resources/`, `datasources/`, versioned (`v3` kubernetes, `v4` grafana)
- Generated: Yes. Committed: Yes. Do not hand-edit.

**`scripts/`:**
- Purpose: Repository tooling in Node (`.cjs`) — changeset CLI, capability registry generation, drift/lint helpers
- Key files: `scripts/changeset/cli.cjs`, `scripts/gen-capability-registry.cjs`, `scripts/lib/drift-scan.cjs`
- Unrelated to the Protoconf pipeline

## Key File Locations

**Entry Points:**
- `test/src/core_test.mpconf`: `main()` returns the map of output path → proto message
- `Makefile`: root build (`protoconf fmt -w`, `protoconf compile -process-templates .`)
- `test/Makefile`: `protoconf mod tidy` + `protoconf compile .` + workflow install

**Configuration:**
- `test/CONFIGSPACE`: declares each module label and its source path
- `test/protoconf.lock`: pinned branch and descriptor-set checksum per module
- `providers.tf`: Terraform providers for root-level applies
- `.terraform.lock.hcl`: provider version lock
- `.gitignore`: excludes `.terraform/`, `*.tfstate*`, `*.tfvars`, `.protoconf_cache`

**Core Logic:**
- `src/platform/core.pinc`: hook chain, `Component`, markers, `GetConfigs`
- `src/terraform/v1/util.pinc`: Terraform message construction and `link()` interpolation
- `drivers/cicd/github_actions/src/github_actions.pinc`: pipeline derivation from configs
- `drivers/monitoring/grafana/src/grafana/alerts.pinc`: burn-rate alert rules

**Generated / Never Hand-Edited:**
- `test/materialized_config/**/*.materialized_JSON`
- `test/outputs/**` and `outputs/**`
- `.github/workflows/terraform.yaml` (copied from `test/outputs/core_test/.github/workflows/`)
- `test/.protoconf_cache/` (git-ignored module cache and `.fds` descriptor sets)

## Naming Conventions

**Files:**
- `.mpconf`: a config space entry point with `main()` — one per stack (`core_test.mpconf`)
- `.pinc`: reusable Starlark library, loaded by `load()`
- `.proto`: message schema, always under a versioned package dir (`v1/`, `v3/`, `v4/`)
- `*.materialized_JSON`: compiler output mirroring an output path
- Driver entry file is named after the driver: `kubernetes.pinc`, `grafana.pinc`, `terraform.pinc`

**Directories:**
- `drivers/<kind>/<name>/src/` — kind is the replaceable role, name is the product
- Proto packages mirror directories: `src/platform/v1/platform.proto` → `package platform.v1`
- Output paths: `<domain>/<component>/<config key>` where a config key is itself a path (`infra/main.tf.json`, `monitoring/main.tf.json`)

**Starlark symbols:**
- `WithX(...)` — a hook or hook pair a call site attaches to a component
- `ForDownstream` / `Finally` / `Inherit` / `WithDeps` — markers, returned as `module(...)`
- Exported facade struct is lowercase (`platform`, `util`, `actions`, `lib`, `alerts`); private helpers take a `_` prefix (`_backend`, `_plan_id`)
- Constants are SCREAMING_SNAKE (`MAIN_CONFIG`, `MONITORING_CONFIG`, `TERRAFORM_VERSION`)

## Where to Add New Code

**New component in the existing stack:**
- Add a `def MyComponent(*hooks)` factory to `test/src/core_test.mpconf` and reference it from `main()` or from another component's `platform.WithDeps(...)`

**New reusable hook (technology-neutral):**
- Implementation: `src/platform/core.pinc` (component/config plumbing) or `src/platform/monitoring.pinc` (objectives)
- Export: add the symbol to the `platform` struct in `src/platform/platform.pinc`

**New Terraform building block:**
- `src/terraform/v1/util.pinc`, and export it from the `util` module struct at the bottom of the file

**New driver (a second runtime, monitoring, state or CI tool):**
- Create `drivers/<kind>/<name>/src/<name>.pinc` plus a `src/v1/dummy.proto`
- Register it in `test/CONFIGSPACE` as a `remote_repo(label=..., url="../drivers/<kind>/<name>", branch="main")`
- Run `protoconf mod tidy` from `test/` to update `test/protoconf.lock`
- Never load one driver from another; drivers depend only on `@platform`

**New message schema:**
- Platform-wide: `src/<package>/v1/*.proto`
- Driver-owned: `drivers/<kind>/<name>/src/<pkg>/v1/*.proto`
- Register any new renderable config type in `CONFIG_TYPES` in `src/platform/core.pinc`, keyed by `type.googleapis.com/<package>.<Message>`

## Special Directories

**`test/.protoconf_cache/`:**
- Purpose: Fetched driver modules and their `.fds` descriptor sets
- Generated: Yes. Committed: No (`.gitignore`).

**`materialized_config/` and `outputs/` (repo root): DELETED (phase 01-01, D-05).**
- They held four `aurora-user-api-task` artifacts reachable from no source: there is no root
  `.mpconf`, `CONFIGSPACE` or `protoconf.lock`, so the root build that would regenerate them
  cannot run. Recoverable from git history if ever needed.
- `test/outputs/` and `test/materialized_config/` are now the only generated trees, and the
  only ones `.github/workflows/drift.yaml` asserts on.

**`.github/workflows/`:**
- Purpose: The Terraform plan/apply pipeline
- Generated: Yes — copied by `test/Makefile` from `test/outputs/core_test/.github/workflows/`. Edit `core_test.mpconf`, not the yaml.

**Agent tooling directories (`.claude`, `.codex`, `.cursor`, `.agents`, `agents/`, `gsd-core/`, `.gsd-*` and siblings):**
- Purpose: Multi-assistant scaffolding, not project architecture. Ignore when reasoning about the platform.

---

*Structure analysis: 2026-09-07*
