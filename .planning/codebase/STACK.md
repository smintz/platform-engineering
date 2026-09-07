# Technology Stack

**Analysis Date:** 2026-09-07

This is a configuration-as-code platform-engineering repo. There is no application
runtime: Starlark under `src/` and `drivers/` compiles to Terraform JSON and a GitHub
Actions workflow. The "build" is `protoconf compile`.

## Languages

**Primary:**
- Starlark (Protoconf dialect) — `.pinc` libraries, `.mpconf` entry points. All logic
  lives here: `src/platform/core.pinc`, `src/platform/monitoring.pinc`,
  `src/terraform/v1/util.pinc`, `drivers/*/*/src/*.pinc`, `test/src/core_test.mpconf`
- Protocol Buffers (proto3, plus vendored proto2 provider schemas) — the type system for
  every value the Starlark builds: `src/platform/v1/platform.proto`,
  `src/terraform/v1/meta.proto`, `src/protoconf_terraform/config/v1/config.proto`,
  `drivers/cicd/github_actions/src/github/actions.proto`,
  `drivers/monitoring/grafana/src/grafana/v1/dashboard.proto`,
  `drivers/runtime/ecs/src/aws/ecs/v1/taskdefinition.proto`

**Secondary:**
- HCL — a single root provider stub, `providers.tf` (kubernetes + grafana providers, used
  for `terraform init` / lockfile generation at the repo root)
- Terraform JSON (`*.tf.json`) — generated, not written: `outputs/`, `test/outputs/`
- YAML — generated GitHub Actions workflow, `.github/workflows/terraform.yaml`
- Make — `Makefile`, `test/Makefile`

## Runtime

**Environment:**
- `protoconf` CLI (Go binary, installed at `~/go/bin/protoconf`) — the compiler and
  Starlark interpreter. No Node/Python/JVM runtime for the project itself.
- `terraform` CLI — consumes the compiled output. CI pins `TERRAFORM_VERSION = "1.9.8"`
  (`drivers/cicd/github_actions/src/github_actions.pinc`); locally Homebrew `terraform`.

**Package Manager:**
- Protoconf modules. Dependencies are declared in `test/CONFIGSPACE` as `remote_repo(...)`
  and resolved/pinned by `protoconf mod tidy` into `test/protoconf.lock`
  (per-dep `fileDescriptorSetSum`). Compiled descriptors are cached in
  `test/.protoconf_cache/*.fds` (gitignored via `.protoconf_cache`).
- Terraform provider lockfile: `.terraform.lock.hcl` (root), plus per-state lockfiles in
  generated output dirs such as `test/outputs/core_test/us-east-1/redis/infra/.terraform.lock.hcl`.
- Lockfiles: present.

## Frameworks

**Core:**
- Protoconf — Starlark-for-config with proto-typed messages, hook chains, `remote_repo`
  module resolution, `materialized_config/` (`.materialized_JSON`) → `outputs/` rendering.
- Terraform — the execution engine for everything the Starlark emits.

**Testing:**
- No unit-test framework. The check is a full compile of a reference stack:
  `test/Makefile` runs `protoconf mod tidy && protoconf compile .` and the committed
  `test/outputs/**` / `test/materialized_config/**` are the golden files.

**Build/Dev:**
- `Makefile` (root): `fmt` → `protoconf fmt -w`; `build` → `protoconf compile -process-templates .`;
  `clean` removes `outputs`, `materialized_config`, `.github/workflows/*`.
- `test/Makefile`: `test` target plus `workflows`, which copies
  `test/outputs/core_test/.github/workflows/*.yaml` to the repository root.
- `.vscode/settings.json` maps `*.pconf`/`*.mpconf`/`*.pinc`/`*.proto-validator` to the
  Starlark grammar, `*.materialized_JSON` to JSON, and formats Starlark on save.

## Key Dependencies

**Protoconf modules** (`test/CONFIGSPACE`, all local path repos on branch `main`):
- `platform` → `..` — the vendor-neutral core (`src/platform`, `src/terraform`)
- `github_actions` → `drivers/cicd/github_actions` — CI driver
- `grafana` → `drivers/monitoring/grafana` — dashboards + alert rules driver
- `ecs` → `drivers/runtime/ecs` — AWS ECS runtime driver
- `kubernetes` → `drivers/runtime/kubernetes` — Kubernetes runtime driver
- `terraform_state` → `drivers/state/terraform` — backend/state driver

**Terraform providers** (versions from `.terraform.lock.hcl` and generated
`required_providers` blocks):
- `hashicorp/kubernetes` 3.2.1 — Deployments and Services
- `grafana/grafana` 4.45.2 — dashboards, folders, rule groups, datasource lookups

**Vendored provider schemas** (proto form of provider resources, consumed via `load()`):
- `terraform/kubernetes/provider/v3/kubernetes.proto`, `.../resources/v3/{deployment,service}.proto`
- `terraform/grafana/provider/v4/grafana.proto`, `.../resources/v4/*.proto`,
  `.../datasources/v4/*.proto` (mirrored under `test/src/terraform/grafana/`)
- `terraform/aws/resources/v5/iam.proto`, `terraform/builtin/datasources/v1/remote_state.proto`
- Starlark stdlib modules: `any.star`, `re.star`, `encoding/json.star`, and WKTs
  `google/protobuf/{struct,wrappers,any}.proto`

## Configuration

**Environment:**
- Nothing is read from the local environment at compile time; every knob is a Starlark
  argument. Runtime credentials are injected by CI (see INTEGRATIONS.md).
- Repo variables/secrets referenced by the generated workflow: `vars.TF_PLAN_ROLE`,
  `vars.TF_APPLY_ROLE`, `vars.GRAFANA_WORKSPACE_ID`, and optionally
  `secrets.AWS_ACCESS_KEY_ID` / `secrets.AWS_SECRET_ACCESS_KEY`.
- No `.env` file exists in this repo.

**Build:**
- `test/CONFIGSPACE` — module graph
- `test/protoconf.lock` — pinned descriptor sums
- `providers.tf` — root Terraform provider stub
- `.gitignore` — excludes `.terraform/`, `*.tfstate*`, `*.tfvars`, `.protoconf_cache`

**Per-stack configuration** is a single `.mpconf` `main()`; `test/src/core_test.mpconf` is
the reference: it picks the backend (`S3Backend`), the datasource names, `OUTPUT_ROOT`, the
SLO windows and queries, and returns the output map.

## Platform Requirements

**Development:**
- `protoconf` on `PATH`, `terraform` on `PATH`, `make`
- A kubeconfig at `~/.kube/config` for the Kubernetes driver's default provider
  (`drivers/runtime/kubernetes/src/kubernetes.pinc`, `KUBECONFIG`)

**Production:**
- GitHub Actions `ubuntu-latest` runners (`drivers/cicd/github_actions/src/github/lib.pinc`)
  running Terraform 1.9.8 with a plugin cache at `/home/runner/.terraform.d/plugin-cache`
  and a 5m state lock timeout.
- Terraform state in S3 (bucket named by the `.mpconf`); GCS, AzureRM, Terraform
  Cloud/Enterprise `remote`, and `local` backends are all implemented in
  `drivers/state/terraform/src/terraform.pinc`.

## Repo Tooling (not project stack)

`.claude/`, `.codex/`, `.cursor/`, `.gemini`-style dirs, `.agents/`, `agents/`,
`gsd-core/`, `.gsd-*`, `scripts/*.cjs` and `AGENTS.md` are AI-agent/GSD scaffolding
installed into the repo. They carry their own Node hook scripts and have no relationship
to the Protoconf/Terraform stack.

---

*Stack analysis: 2026-09-07*
