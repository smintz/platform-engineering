# Codebase Concerns

**Analysis Date:** 2026-09-07

## Tech Debt

**Two divergent copies of the Terraform Starlark helpers:**
- Issue: `src/terraform/v1/util.pinc` and `test/src/terraform/v1/util.pinc` are the same library, forked. The test copy is 161 lines ahead (empty-hook-list-safe `Chain`, `Last`/`ChainWithLast` removed, provider dedup at insertion time, `_TERRAFORM_TYPE_URL` constant, docstrings). The `src/` copy still carries the old `Chain` that crashes on an empty hook list and the "fixes a bug in any.pack which duplicates entries in repeated providers" post-pass in `GenerateTerraformConfigs`.
- Files: `src/terraform/v1/util.pinc`, `test/src/terraform/v1/util.pinc`
- Impact: The `platform` module published via `test/CONFIGSPACE` (`url=".."`) resolves `@platform//terraform/v1/util.pinc` to the *root* copy, so drivers run against the old code while the test tree carries the fixes. Bug fixes land in the copy nobody imports.
- Fix approach: Delete `test/src/terraform/v1/util.pinc`, port its improvements into `src/terraform/v1/util.pinc`, and let the test module load it through `@platform//`.

**`src/` cannot compile standalone:**
- Issue: `src/terraform/v1/util.pinc:5` does `load("terraform.proto", ...)`, but `src/terraform/v1/` contains only `meta.proto` and `util.pinc`. `terraform.proto` (the generated provider schema, ~1200+ lines) exists only under `test/src/terraform/v1/`.
- Files: `src/terraform/v1/util.pinc`, `test/src/terraform/v1/terraform.proto`
- Impact: The root `Makefile` target `protoconf compile -process-templates .` has no root `CONFIGSPACE` and no root `protoconf.lock`; the only working build is `make -C test`. `make` at the repo root is broken/decorative.
- Fix approach: Either add a root `CONFIGSPACE`/lock and vendor the generated `terraform.proto` into `src/terraform/v1/`, or delete the root build targets and document `test/Makefile` as the entry point.

**Stale generated artifacts checked in at the repo root:**
- Issue: `outputs/platform/core_test/us-east-1/aurora-user-api-task/**` and the matching `materialized_config/platform/...` describe an `aurora-user-api-task` component that no longer exists in any `.mpconf`. The live stack (`test/src/core_test.mpconf`) emits `api-task` and `redis` under `test/outputs/`.
- Files: `outputs/platform/core_test/us-east-1/aurora-user-api-task/infra/main.tf.json`, `outputs/platform/core_test/us-east-1/aurora-user-api-task/aurora_endpoint.tf.json`, `materialized_config/platform/core_test/us-east-1/aurora-user-api-task/*`
- Impact: Two output trees, one of them unreachable from any source. A reader cannot tell which is authoritative; `make clean` deletes both.
- Fix approach: `git rm -r outputs/ materialized_config/` at the root; keep only `test/outputs/` and `test/materialized_config/`.

**Root `providers.tf` is orphaned:**
- Issue: `providers.tf` declares bare `provider "kubernetes" {}` / `provider "grafana" {}` and a `required_providers` block with no version constraint, at a repo root that is not a Terraform working directory (no state, no resources, `.terraform.lock.hcl` gitignored).
- Files: `providers.tf`
- Impact: Dead config that contradicts the generated, version-pinned `main.tf.json` files. Anyone running `terraform` at the root gets an unpinned provider set.
- Fix approach: Delete it, or move it under a real working directory with a pinned version.

**`TODO(smintz)` in the component schema:**
- Issue: `src/platform/v1/platform.proto:68` — `// TODO(smintz): Fill this out`, an undocumented field in the core `Component` message.
- Files: `src/platform/v1/platform.proto`
- Impact: The one schema every driver depends on has an unspecified field.
- Fix approach: Document or remove the field before more drivers bind to it.

## Known Bugs

**`Walk` iterates the wrong field:**
- Symptoms: `src/terraform/v1/util.pinc:161-164` iterates `component.upstreams` directly, while `Component.upstreams` is an `Upstreams` message whose members live in `.components` (see `src/platform/core.pinc:208`). Any traversal through `GenerateTerraformConfigs` visits no dependency.
- Files: `src/terraform/v1/util.pinc` (`Walk`, `GenerateTerraformConfigs`), `src/platform/core.pinc` (`GetConfigs`)
- Trigger: Calling `GenerateTerraformConfigs` on a component that declares `WithDeps`.
- Workaround: The live stack uses `platform.GetConfigs` (`test/src/core_test.mpconf:112`), which walks `upstreams.components` correctly. `GenerateTerraformConfigs` is the unused, broken duplicate of the same job.

**`redis/infra` has no remote backend:**
- Symptoms: `test/outputs/core_test/us-east-1/redis/infra/main.tf.json` renders `"backend": {"local": {}}` while every sibling state renders the S3 backend.
- Files: `test/src/core_test.mpconf:50` (`WithState(lambda component: Workload(...))` — the `BACKEND` argument that line 81 passes for `api-task` is missing), `drivers/state/terraform/src/terraform.pinc` (`DEFAULT_BACKEND = LocalBackend()`)
- Trigger: The generated apply job runs `terraform apply -auto-approve` on an ephemeral GitHub runner. Local state is written to the runner's disk and discarded, so every run replans from empty and re-creates the Redis Deployment and Service.
- Workaround: None in place. Pass `BACKEND` to `WithState` for `redis`, and consider making a missing backend a compile error for any config the CI driver is asked to apply.

## Security Considerations

**Local developer path baked into a committed lockfile:**
- Risk: `test/protoconf.lock` records `"getterUrl": "file:///Users/smintz/git/platform-engineering/..."` for all six modules.
- Files: `test/protoconf.lock`
- Current mitigation: None. `test/CONFIGSPACE` uses relative URLs (`..`, `../drivers/...`), so the absolute paths come from resolution, not declaration.
- Recommendations: Leaks a username and a machine layout, and breaks any checkout not at that exact path. Regenerate the lock from a path-independent resolution, or exclude `getterUrl` from the committed lock.

**`terraform apply -auto-approve` on `main` with no approval gate:**
- Risk: `.github/workflows/terraform.yaml` applies four states automatically on push to `main` using `${{ vars.TF_APPLY_ROLE }}` via OIDC, with no `environment:` protection rule.
- Files: `.github/workflows/terraform.yaml`, `drivers/cicd/github_actions/src/github_actions.pinc:493,511,527`
- Current mitigation: `id-token: write` with a role assumed per job; the plan artifact is what gets applied, not a fresh plan.
- Recommendations: The driver already supports an `environment` argument (`github_actions.pinc:580,626`) — `test/src/core_test.mpconf` does not set it. Wire a protected environment for the apply jobs.

**S3 backend without state locking:**
- Risk: `S3Backend` (`drivers/state/terraform/src/terraform.pinc`) emits only `bucket`, `key`, `region`. No `dynamodb_table`, no `use_lockfile`, no `encrypt` — all of which exist in the schema (`test/src/terraform/v1/terraform.proto:1045,1059`).
- Files: `drivers/state/terraform/src/terraform.pinc` (`S3Backend`), generated `test/outputs/core_test/us-east-1/*/main.tf.json`
- Current mitigation: The workflow passes `-lock-timeout=5m`, which does nothing when the backend supports no lock, plus a `concurrency: terraform-${{ github.ref }}` group that only serialises runs on the same ref.
- Recommendations: Add `dynamodb_table`/`use_lockfile` and `encrypt = true` to `S3Backend`. Two refs applying at once currently corrupt state silently.

**Grafana token minting deletes tokens it does not own:**
- Risk: The `grafana-token` step lists every service-account token and deletes the ones whose `expiresAt` string sorts before `now`, with `|| true` swallowing failures.
- Files: `.github/workflows/terraform.yaml` (the `grafana-token` step, duplicated in four jobs), `drivers/cicd/github_actions/src/github_actions.pinc:271`
- Current mitigation: String comparison on the first 19 chars, and the comment acknowledges the race with sibling jobs.
- Recommendations: Timezone or format variation in `expiresAt` makes the comparison wrong in both directions — either leaking live tokens or deleting them. Delete only tokens this workflow named (`gha-$GITHUB_RUN_ID-...`), or let them expire.

**No validators anywhere in the repo:**
- Risk: Zero `.proto-validator` files, zero `add_validator` calls, no `buf.validate`/`validate.proto` annotations across `src/`, `drivers/`, and `test/src/`.
- Files: entire `src/` and `drivers/` tree
- Current mitigation: Starlark `fail()` in exactly two places — `LocalBackend.config_for` and the `terraform_remote_state` cycle check (`drivers/cicd/github_actions/src/github_actions.pinc:170`).
- Recommendations: The `redis/infra` local-backend bug is precisely what a cross-field validator catches at compile time ("a config the CI driver applies must not use a local backend"). Add validators for backend presence, non-empty bucket/key, and SLO bounds (`min`/`max` both 0 is currently legal).

## Performance Bottlenecks

**Provider dedup runs as a post-pass over the whole config:**
- Problem: `GenerateTerraformConfigs` in `src/terraform/v1/util.pinc:178-182` walks every provider type of every config and rebuilds each list through `set()` to undo duplicate entries.
- Files: `src/terraform/v1/util.pinc`
- Cause: Duplicates are created upstream by `Provider` appending unconditionally.
- Improvement path: The fix already exists in `test/src/terraform/v1/util.pinc` (dedup at insertion). Merging the two copies removes the post-pass.

**Terraform plugin cache key hashes a file that is never committed:**
- Problem: Every plan and apply job keys its cache on `hashFiles('test/outputs/.../.terraform.lock.hcl')`, but `.gitignore` excludes `.terraform.lock*`, so the file is absent on a fresh checkout.
- Files: `.gitignore`, `.github/workflows/terraform.yaml`
- Cause: `hashFiles` on a missing path returns an empty string, so all eight jobs share one degenerate key and the `restore-keys` prefix silently decides what gets restored.
- Improvement path: Commit the per-state `.terraform.lock.hcl` (that is what it is for) and narrow the `.gitignore` rule to `.terraformrc`/`terraform.rc` only.

## Fragile Areas

**`make clean` deletes hand-written workflows:**
- Files: `Makefile` (`clean: rm -rvf outputs materialized_config .github/workflows/*`)
- Why fragile: It wipes the whole `.github/workflows` directory, not just the generated `terraform.yaml`, and the generated one can only be restored via `make -C test workflows`.
- Safe modification: Delete `.github/workflows/terraform.yaml` by name.
- Test coverage: None.

**Generated workflow installed by file copy:**
- Files: `test/Makefile` (`workflows` target), `.github/workflows/terraform.yaml`, `test/outputs/core_test/.github/workflows/terraform.yaml`
- Why fragile: `cp` into `../.github/workflows/` with no drift check. `test/src/core_test.mpconf:21` hardcodes `OUTPUT_ROOT = "test/outputs/core_test"`, which must stay in lockstep with the actual output location or every `working-directory` and the `paths:` filter in the workflow point at nothing — and the workflow simply stops triggering, silently.
- Safe modification: Change `OUTPUT_ROOT` and the compiler output path together; add a CI check that recompiles and diffs `.github/workflows/terraform.yaml`.
- Test coverage: None — nothing verifies the committed workflow matches what the compiler produces.

**Kubernetes provider pinned to a workstation kubeconfig:**
- Files: `drivers/runtime/kubernetes/src/kubernetes.pinc:23` (`KUBECONFIG = "~/.kube/config"`), rendered into `test/outputs/core_test/us-east-1/*/infra/main.tf.json` as `"config_path": "~/.kube/config"`
- Why fragile: The GitHub runner has no `~/.kube/config` and the workflow's only credential step is AWS OIDC — no `aws eks update-kubeconfig`, no in-cluster auth. Both `infra` applies fail on the runner while working on a laptop.
- Safe modification: Make the provider caller-supplied per environment (the driver already accepts a `provider` override at `kubernetes.pinc:51`), and add an EKS/kubeconfig step to the CI driver.
- Test coverage: None.

**Hook ordering is load-bearing and undocumented outside comments:**
- Files: `src/platform/core.pinc:148,155-167`
- Why fragile: `Component` depends on inherited hooks running first, the main config being mutated before the component chain, deps built after the chain, and finalizers last. A reordering breaks `WithFailureDomain`-derived values and `ForDownstream` config writes with no error — just wrong output.
- Safe modification: Change nothing in `Component`'s body without regenerating `test/outputs/` and diffing.
- Test coverage: The committed `test/outputs/` tree is the only regression signal, and comparing it is a manual step.

## Scaling Limits

**One workflow file, two jobs per state:**
- Current capacity: 4 states → 9 jobs in a single `.github/workflows/terraform.yaml`.
- Limit: The file is fully unrolled — each state duplicates the ~30-line `grafana-token` script and the whole plan/apply scaffold. At a few dozen states this hits GitHub's job-per-workflow limits and becomes unreviewable.
- Scaling path: Emit a matrix, or one workflow per failure domain; factor the Grafana token script into a composite action.

**PR comment truncation:**
- Current capacity: 60000-character budget split evenly across changed states (`.github/workflows/terraform.yaml`, `pr_comment` job).
- Limit: With many states the per-plan share shrinks toward the 200-char floor and every plan is truncated to nothing useful.
- Scaling path: Post per-state comments, or link the artifact instead of inlining.

## Dependencies at Risk

**All six protoconf modules pinned to `branch = "main"`:**
- Risk: `test/CONFIGSPACE` pins every module to a moving branch, not a tag or commit. The `fileDescriptorSetSum` in `test/protoconf.lock` is the only thing recording what was actually built, and `kubernetes` and `terraform_state` share the identical sum (`175efcd4...`) because both contain nothing but a stub `v1/dummy.proto`.
- Files: `test/CONFIGSPACE`, `test/protoconf.lock`, `drivers/runtime/kubernetes/src/v1/dummy.proto`, `drivers/state/terraform/src/v1/dummy.proto`
- Impact: The modules are file:// paths inside this same repo, so "one module per driver" buys separation of imports but not independent versioning — a change to a driver is picked up by whatever `protoconf mod tidy` last resolved.
- Migration plan: Pin to tags once drivers move to their own repos; until then, treat `test/protoconf.lock` as the pin and fail the build when it changes unexpectedly.

## Missing Critical Features

**No CI job compiles the protoconf sources:**
- Problem: The only workflow is the generated `terraform.yaml`, which runs `terraform` against committed `.tf.json`. Nothing runs `protoconf compile` or `protoconf fmt --check`.
- Blocks: `test/outputs/` and `test/materialized_config/` can silently drift from `test/src/` and `drivers/`; a `.pinc` that no longer compiles merges green.

**No CI ordering for non-state dependencies:**
- Problem: The pipeline orders jobs only by `terraform_remote_state` edges (`drivers/cicd/github_actions/src/github_actions.pinc:104-119`). `redis` reaches `api-task` through `ForDownstream` + `WithContainerEnv("REDIS_URL", ...)` — a literal string, not a remote state — so the generated workflow gives the two `infra` applies no ordering at all.
- Blocks: `api-task` can apply before the Redis it points at exists.

## Test Coverage Gaps

**Nothing executes as a test:**
- What's not tested: `test/Makefile`'s `test` target runs `protoconf mod tidy && protoconf compile . && cp`. It asserts nothing — a successful compile that emits different output than what is committed still "passes".
- Files: `test/Makefile`, `test/outputs/**`, `test/materialized_config/**`
- Risk: Every behaviour in `src/platform/core.pinc` (hook chaining, `message_filter`, `WithDeps`/`Inherit`/`ForDownstream`/`Finally` ordering, `GetConfigs` empty-config skipping) is unverified.
- Priority: High — add `git diff --exit-code test/outputs test/materialized_config` after compile, in CI.

**Backend and CI driver logic untested:**
- What's not tested: `_backend`'s settings/config_for symmetry (the comment at `drivers/state/terraform/src/terraform.pinc:20-23` calls a mismatch here a silent failure), the `terraform_remote_state` cycle detection, and `_remote_state_id` across all five backend kinds.
- Files: `drivers/state/terraform/src/terraform.pinc`, `drivers/cicd/github_actions/src/github_actions.pinc`
- Risk: A backend whose reader disagrees with its writer reads an empty state and plans a full re-create.
- Priority: High.

**`GetConfigs` empty-config heuristic:**
- What's not tested: `src/platform/core.pinc:201` skips a config when `str(cfg) == str(proto())` — string comparison of a whole message as an emptiness test.
- Files: `src/platform/core.pinc`
- Risk: A config that is meaningfully empty-but-present is dropped; proto text formatting changes break the check.
- Priority: Medium.

---

*Concerns audit: 2026-09-07*
