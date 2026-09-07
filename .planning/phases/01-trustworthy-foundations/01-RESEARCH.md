# Phase 1: Trustworthy Foundations - Research

**Researched:** 2026-09-07
**Domain:** Protoconf/Starlark compile pipeline, GitHub Actions CI, Terraform state topology
**Confidence:** HIGH — every load-bearing claim below was reproduced by running the real toolchain against real copies of this repo this session, not read off a map.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Drift Check (FOUND-01)**

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

**Drift Check Scope (FOUND-01)**

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

**Component Shape (FOUND-02)**

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

**SelectComponents (FOUND-03)**

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

**Compile-Time Enforcement (FOUND-04, FOUND-05)**

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

### Deferred Ideas (OUT OF SCOPE)

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

> **Note on the last deferred item.** The absolute path in `test/protoconf.lock` is **not**
> deferrable for this phase. Section "Pitfall 1" below shows, with pasted failing output, that it
> makes `protoconf mod tidy`, `protoconf mod sync` and `protoconf compile` all exit 1 on any
> machine where `/Users/smintz/git/platform-engineering` does not exist — i.e. on every GitHub
> Actions runner. FOUND-01 cannot ship without handling it. The verified minimal handling is in
> the drift-check recipe below; it does not require changing the committed lock.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| FOUND-01 | CI fails the build when committed generated output differs from a fresh `protoconf compile` of the source | Verified install recipe (pinned release binary + sha256), verified CI-safe build recipe that works around the absolute-path lock, verified byte-reproducibility of all 10 golden files at a foreign filesystem path, and the exact `git` invocation that also catches *new untracked* outputs — §Standard Stack, §Code Examples 1-2, §Pitfalls 1-3 |
| FOUND-02 | A component carries declared key/value tags (`platform.v1.Component.tags`) that describe its shape | `Component.Metadata.labels` read verbatim from the schema; verified that `component.metadata` is `None` until constructed and that `labels` supports `[]=` / `.get` / `.items()` / `in`; verified a `WithLabels(**labels)` `component_filter` hook works — §Code Examples 3, §Pitfall 4 |
| FOUND-03 | A platform author can select every component in a dependency graph matching a predicate, via an exported `SelectComponents` | Verified that proto messages are **hashable and structurally equal** in this Starlark, so a `dict` de-duplicates diamond repeats; verified the factored traversal leaves all 10 golden files byte-identical (D-12); verified selection, ordering, and empty-result behaviour on a real diamond graph — §Code Examples 4, §Pitfall 5 |
| FOUND-04 | Compile fails with a message naming the fix when a component whose state CI will apply has no remote backend configured | Verified that **every** config gets an apply job unconditionally, so the check's scope is simply every key in `configs`; verified `backend.local` is truthy for the empty `BackendLocal` redis renders; prototype check pasted with its real firing output — §Code Examples 5 |
| FOUND-05 | A cross-state value handshake authored by any driver is visible to CI apply-ordering derivation, or compile fails | Verified `_reads`/`_backend_state_id` already produce comparable ids; prototype check pasted with both its firing output (mismatched handshake backend) and its silence on the correct DATA-05 pattern — §Code Examples 6, §Pitfall 6 |

</phase_requirements>

## Summary

This phase touches four small places in a working system, and almost all the risk is concentrated
in one of them. FOUND-02, FOUND-03, FOUND-04 and FOUND-05 are each 10-30 lines of Starlark in
files that already contain the machinery they need; I built all four in a scratch copy of this
repo this session, compiled the reference stack against them, and they work. FOUND-01 is the one
that is not what it looks like: `cd test && make test` **cannot run on a GitHub Actions runner
today**, and no amount of workflow YAML fixes that, because the cause is a machine-absolute path
committed inside `test/protoconf.lock`.

The mechanism is worth stating precisely, because it is invisible from the codebase map.
`protoconf mod tidy` resolves each `remote_repo` by go-getter and then **symlinks**
`test/.protoconf_cache/<label>` at the resolved absolute path — on this machine every entry is a
symlink into `/Users/smintz/git/platform-engineering`. That absolute path is written into the
lock as `getterUrl` and **committed**. On a machine where the path does not exist, `mod sync`
exits 1, `mod tidy` exits 1 and does *not* re-resolve from the relative `url`, and `compile` then
exits 1 on an empty cache. The verified fix costs one line in the workflow: `rm -f
test/protoconf.lock` before `mod tidy`, which makes tidy regenerate the lock from `CONFIGSPACE`'s
relative urls against the runner's own checkout path. With that one line, a clean `git archive`
of HEAD unpacked at a completely unrelated filesystem path reproduced **all ten** committed
golden files byte-for-byte using the public release binary.

Two secondary corrections the planner needs. First, D-16 predicts that giving Redis a real
backend changes the generated pipeline's job ordering — **it does not**. No config in the
reference stack declares a `terraform_remote_state` today, so there are no ordering edges to
change; the fix produces exactly two changed files and `.github/workflows/terraform.yaml` stays
byte-identical. Any workflow diff in that plan is a regression, not the expected change. Second,
`git diff --exit-code` does not see untracked files, so a change that adds a *new* output file
(a new component, a new state) would pass a naive drift check green.

**Primary recommendation:** Write the drift workflow around a pinned `protoconf v0.2.0-rc2`
release tarball verified by sha256, `rm -f test/protoconf.lock` before `make test`, and assert
with `git add -A -- <paths> && git diff --cached --exit-code -- <paths>` scoped to the three trees
D-02 names. Then land FOUND-02..05 exactly as prototyped in §Code Examples, with the redis
`BACKEND` fix in the same plan as the FOUND-04 check.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Drift detection (FOUND-01) | CI / GitHub Actions (hand-written) | Build tooling (`test/Makefile`) | D-01: the artifact under test is the generated pipeline, so the checker must live outside the generator. It is an assertion about the repository, not about any component. |
| Component shape vocabulary (FOUND-02) | Component schema (`src/platform/v1/platform.proto`) | Platform core hook (`core.pinc`) | The field already exists; only a hook that writes it is missing. Shape is a property of a component in isolation, so it belongs in the platform layer, not a driver. |
| Graph selection (FOUND-03) | Platform core (`src/platform/core.pinc`) | Facade (`src/platform/platform.pinc`) | Traversal of `Component.upstreams` is the platform's own data structure. No driver may own it — drivers are replaceable and this is not. |
| Backend-presence enforcement (FOUND-04) | CI driver (`github_actions.pinc`) | — | D-14: the assertion is "this config will get an apply job on an ephemeral runner". Only the pipeline builder knows that. A `.proto-validator` bound to `Component` is structurally unable to see it. |
| Cross-state read visibility (FOUND-05) | CI driver (`github_actions.pinc`) | State driver (`terraform.pinc`, as the thing being asserted about) | Same reason. The producer set exists only once `GetConfigs` has been flattened into a pipeline; a single component cannot know whether its read is satisfied. |
| Reference-stack correctness (redis `BACKEND`) | Call site (`test/src/core_test.mpconf`) | — | Bucket names and key layouts are call-site policy by explicit architectural rule (`.planning/codebase/ARCHITECTURE.md`, "Baking organisation specifics into a driver"). |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `protoconf` | `v0.2.0-rc2` | The compiler. Turns `.mpconf`/`.pinc` into `materialized_config/` + `outputs/`. | It is the project's build. `[VERIFIED: github.com/protoconf/protoconf releases API]` — `v0.2.0-rc2`, published `2026-09-03T02:15:47Z`, is the newest release; the only newer tags are the older `v0.2.0-rc1`, `v0.2.0-alpha2`, `v0.2.0-alpha1`. |
| GitHub Actions `ubuntu-latest` | n/a | Runner for the drift workflow. | Already the runner every generated job uses `[VERIFIED: drivers/cicd/github_actions/src/github/lib.pinc]`. |
| `actions/checkout` | `v4` | Check out the repo in the drift workflow. | Consistency with the generated pipeline, which pins `actions/checkout@v4` `[VERIFIED: drivers/cicd/github_actions/src/github_actions.pinc:387 — `lib.Step("checkout", lib.Uses("actions/checkout@v4"))`]`. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `make` | any | `cd test && make test` is the build D-02 wraps. | Present on `ubuntu-latest` by default. |
| `git` | any | The assertion half of the drift check. | Always. |

**Deliberately NOT in the stack:** `terraform`. The drift check compiles and diffs; it never
plans or applies. Installing Terraform in the drift workflow would add ~30s and buy nothing.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Pinned release tarball | `go install github.com/protoconf/protoconf/cmd/protoconf@v0.2.0-rc2` | Works (the module path is confirmed — see below), but needs `actions/setup-go` plus a ~2 min build of a very large dependency tree on every run. The release tarball is a 29 MB download and an untar. Prefer the tarball. |
| Pinned release tarball | `latest` release | Directly forbidden by D-04, and correctly: an unpinned compiler makes every drift result a moving target. |
| `git diff --exit-code` | `git status --porcelain` + fail on non-empty | Equivalent; `git add -A` + `git diff --cached --exit-code` is preferred because it prints the actual diff in the log, which is the thing the contributor needs to see. |
| `make test` | `protoconf mod sync && protoconf compile .` | `mod sync` uses the pinned lock rather than re-resolving, which is the more CI-correct verb — but it fails identically on the absolute-path lock, so it buys nothing here, and D-02 locks `make test`. Use `make test`. |

**Installation (drift workflow, verified recipe):**

```bash
PROTOCONF_VERSION=0.2.0-rc2
PROTOCONF_SHA256=eeb8415960567e23f1a3a4acb8eb28a07cb68a544c4c2e3fd41fb7ebdfde9f3a
curl -fsSL -o /tmp/protoconf.tar.gz \
  "https://github.com/protoconf/protoconf/releases/download/v${PROTOCONF_VERSION}/protoconf_${PROTOCONF_VERSION}_linux_amd64.tar.gz"
echo "${PROTOCONF_SHA256}  /tmp/protoconf.tar.gz" | sha256sum -c -
sudo tar -xzf /tmp/protoconf.tar.gz -C /usr/local/bin protoconf
protoconf --version   # -> "protoconf 0.2.0-rc2"
```

**Version verification.** `[VERIFIED: github.com/protoconf/protoconf releases API + checksums.txt]`
The `v0.2.0-rc2` release ships six assets. The full published `checksums.txt`, fetched this
session, is:

```
bebd596d375b6cb0d0e65c2d9e9d252c7c23b80cb7b29fb4740d012997fb46da  protoconf_0.2.0-rc2_darwin_amd64.tar.gz
f643b4eb6d8c4d6e3b4f4ea8507c8ca21000b70b56db283a5d3197b835e96ac5  protoconf_0.2.0-rc2_darwin_arm64.tar.gz
96568143b66d9b14a50e71419fff82b560106c2cfe7eda5272867b5a9ff6368e  protoconf_0.2.0-rc2_linux_386.tar.gz
eeb8415960567e23f1a3a4acb8eb28a07cb68a544c4c2e3fd41fb7ebdfde9f3a  protoconf_0.2.0-rc2_linux_amd64.tar.gz
20a810a56bfa46fe4c3315955aafcc4f76e27da1b45785b444544d20989ac7c8  protoconf_0.2.0-rc2_linux_arm64.tar.gz
```

I downloaded `protoconf_0.2.0-rc2_darwin_arm64.tar.gz` and `shasum -a 256` returned
`f643b4eb6d8c4d6e3b4f4ea8507c8ca21000b70b56db283a5d3197b835e96ac5` — matching the published
checksum exactly. The tarball extracts a single `protoconf` binary at its root (alongside
`README.md`, `LICENSE`, `CHANGELOG.md`), so `tar -xzf ... -C /usr/local/bin protoconf` is
sufficient; there is no nested directory.

**The go module path, if the planner prefers `go install`:** `[VERIFIED: go version -m ~/go/bin/protoconf]`
the locally installed binary reports `path github.com/protoconf/protoconf/cmd/protoconf`.

**A caveat that turned out not to matter.** The `protoconf` on this developer's `PATH` is *not*
a release build: `go version -m` reports it built from
`github.com/protoconf/protoconf v0.2.0-rc2.0.20260907140707-57725ef97de6+dirty`, and that commit
(`57725ef`, "docs(11): add code review report") lives on `origin/perf/compiler`, not `main`. It
reports `protoconf 0.0.1` rather than `0.2.0-rc2`. I therefore treated "does the public release
reproduce the committed goldens?" as an open question and tested it directly: it does, byte for
byte, for all ten files. See §Code Examples 2 for the transcript.

## Package Legitimacy Audit

This phase installs no npm/PyPI/crates package. It downloads one binary release and references
one GitHub Action, both audited by direct inspection rather than a registry heuristic.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| `protoconf` `v0.2.0-rc2` | GitHub Releases (`protoconf/protoconf`) | released 2026-09-03; project's release history runs back to `0.1.4` in 2021 | n/a (binary release) | github.com/protoconf/protoconf | OK | Approved — sha256-pinned; checksum of the actually-downloaded artifact verified against the published `checksums.txt` this session |
| `actions/checkout@v4` | GitHub Marketplace | n/a | n/a | github.com/actions/checkout | OK | Approved — already used by the repo's own generated pipeline at `github_actions.pinc:387` |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

*The `gsd-tools query package-legitimacy check` seam covers npm/PyPI/crates and has no ecosystem
for a GitHub release tarball; the substitute performed here — fetch the publisher's own
`checksums.txt`, download the artifact, and compare — is stronger for this artifact class, since
it pins the exact bytes rather than a name.*

## Architecture Patterns

### System Architecture Diagram

The two flows this phase adds, drawn against the existing pipeline:

```text
  FOUND-01: the drift check (a second, independent path over the same build)
  ─────────────────────────────────────────────────────────────────────────

   PR touching test/src/**, src/**, drivers/**,          existing pipeline
   test/CONFIGSPACE, test/protoconf.lock                 (generated, unchanged)
             │                                            triggers on
             ▼                                            test/outputs/core_test/**
   ┌──────────────────────────┐                                  │
   │ drift.yaml (hand-written)│                                  ▼
   │  actions/checkout@v4     │                       terraform plan / apply
   └────────────┬─────────────┘
                ▼
   install pinned protoconf (sha256-verified tarball)
                │
                ▼
   rm -f test/protoconf.lock   ◄── REQUIRED: committed lock holds an
                │                   absolute path that does not exist here
                ▼
   cd test && make test
     ├─ protoconf mod tidy   → regenerates lock, symlinks .protoconf_cache
     ├─ protoconf compile .  → writes test/materialized_config/, test/outputs/
     └─ make workflows       → cp outputs/.../terraform.yaml → ../.github/workflows/
                │
                ▼
   git add -A -- test/materialized_config test/outputs .github/workflows/terraform.yaml
   git diff --cached --exit-code -- (same three paths)
                │
      ┌─────────┴─────────┐
   exit 0                exit 1 + message telling the contributor
   (in sync)             to run `cd test && make test` and commit


  FOUND-04/05: two new compile-time gates inside TerraformPipeline
  ───────────────────────────────────────────────────────────────

   main() in core_test.mpconf
        │  platform.GetConfigs(component.msg)
        ▼
   configs: {"<domain>/<name>/<config>": terraform.v1.Terraform}
        │
        ▼
   actions.TerraformPipeline(configs, ...)
        │
        ├─► _check_remote_backends(configs)        ← NEW (FOUND-04)
        │     for every key: config.terraform.backend must exist
        │     and must not be `local` — because every key below
        │     unconditionally gets an apply job on an ephemeral runner
        │
        ├─► _check_reads_are_produced(configs)     ← NEW (FOUND-05)
        │     every _remote_state_id(...) in _reads(config) must be
        │     a key of _producers(configs)
        │
        ├─► dependencies(configs) ──► _producers(configs)  ← EXTRACTED
        │     (backend state id → the config that writes it)
        ├─► _check_acyclic(deps)
        ├─► job-id collision fail()      (existing, line 603)
        └─► _plan_job + _apply_job per config, + _comment_job
```

### Recommended Project Structure

No new directories. Five files change:

```
.github/workflows/
└── drift.yaml                              # NEW, hand-written (D-01)
src/platform/
├── core.pinc                               # walk_upstreams to module level + SelectComponents
└── platform.pinc                           # export SelectComponents through the facade
drivers/cicd/github_actions/src/
└── github_actions.pinc                     # _producers, _check_remote_backends,
                                            # _check_reads_are_produced
test/src/
└── core_test.mpconf                        # redis: pass BACKEND to WithState
outputs/, materialized_config/              # DELETED at repo root (D-05)
```

Optional sixth, recommended (see §Don't Hand-Roll):

```
test/src/
└── select_test.mpconf                      # NEW: a negative test that fail()s if
                                            # SelectComponents misbehaves; returns {} so
                                            # it writes no output file
```

### Pattern 1: A traversal with one owner and two consumers

**What:** Lift `walk_upstreams` from a closure inside `GetConfigs` to a module-level function,
leaving `GetConfigs` a consumer of it rather than its owner.
**When to use:** Exactly D-10. Do not write a second walk.
**Verified:** After this change, all ten golden files are byte-identical. Transcript in
§Code Examples 4.

### Pattern 2: De-duplicating by structural equality

**What:** `found = {}; found[component] = True; return found.keys()`.
**Why it is safe here:** proto messages in this Starlark dialect are **hashable** and compare by
**value**, verified this session (§Pitfall 5). This matters more than it sounds: in a diamond,
`Component` calls `dep_factory(...)` once *per parent*, so the two "same" upstreams are literally
two distinct message objects. Reference identity would not de-duplicate them at all. Structural
equality does.
**Verified:** On a `top → {mid1, mid2} → leaf` diamond, `SelectComponents(top, lambda c: True)`
returned `["leaf", "mid1", "mid2", "top"]` — `leaf` once, post-order preserved.

### Pattern 3: One producer map, three consumers

**What:** Extract the state-id→config map that `dependencies()` builds today into a module-private
`_producers(configs)`, so `dependencies()`, the FOUND-05 check, and any future check share one
definition of "states this pipeline writes".
**Why:** D-14 places FOUND-05 in `TerraformPipeline`, but the producer map is currently a local
inside `dependencies()`. The choices are: duplicate the loop, change `dependencies()`' public
signature (it is exported in the `actions` struct at `github_actions.pinc:674`), or extract the
helper. Extraction is the smallest diff that leaves the public surface alone.
**Note on D-14's letter vs. its rationale:** D-14 says "next to the existing job-id collision
`fail()` at line 603". The two new checks are best called from `TerraformPipeline` immediately
*before* `dependencies(configs)` (so a missing backend is reported before an ordering derivation
that a missing backend would silently corrupt), with the check bodies defined as module-private
functions above `TerraformPipeline`. That satisfies D-14's rationale — "`TerraformPipeline` is the
only place the check can be true" — exactly; only the line number moves.

### Anti-Patterns to Avoid

- **A `.proto-validator` for FOUND-04/05.** `.planning/codebase/CONVENTIONS.md` prefers validators
  over driver `fail()`s, and D-14 overrides it here with a correct reason. A validator bound to
  `Component` runs before the component is ever flattened into a pipeline and cannot see the
  producer set. Do not "improve" the design back to a validator.
- **Hand-editing `.github/workflows/terraform.yaml`.** It is generated and committed. The new
  `drift.yaml` sits beside it; `terraform.yaml` stays a build output.
- **A `git diff --exit-code` with no `git add`.** It will pass green on a change that *adds* an
  output file. See §Pitfall 3.
- **Making the drift check a job in the generated pipeline.** Forbidden by D-01, and the reason is
  load-bearing rather than stylistic.
- **De-duplicating `SelectComponents` by `"<domain>/<name>"` string.** It works, but it silently
  asserts that domain+name is unique, which nothing enforces. The message-as-dict-key form is
  verified and needs no such assumption.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Walking the component graph | A second recursive walk for `SelectComponents` | The existing `walk_upstreams`, lifted to module level | D-10. Two traversals are two things that can disagree about what the graph is, and only one of them is covered by the golden files. |
| Rendering a backend to a comparable id | New string formatting for FOUND-04/05 | `_backend_state_id(config)` / `_remote_state_id(...)` / `_reads(config)` at `github_actions.pinc:50-106` | They already handle all five backends and already agree with each other by construction. |
| Detecting a local backend | Parsing the rendered JSON, or string-matching `"local://"` | `config.terraform.backend.local` truthiness | Verified: for the redis config, which renders `"backend": {"local": {}}`, the *empty* `BackendLocal` message is **truthy** when the field is set. The structural test is exact; the string test depends on `_backend_state_id`'s formatting staying put. |
| De-duplicating components | An `id()`/index-based identity scheme | A `dict` keyed by the message itself | Verified hashable and value-equal (§Pitfall 5). |
| Finding which configs get an apply job | Any filtering logic | Every key in `configs` | Verified: `TerraformPipeline` appends both a `_plan_job` and an `_apply_job` for every key, unconditionally, with no predicate (`github_actions.pinc:607-630`). FOUND-04's scope is the whole map. |
| Asserting a `fail()` actually fires | A shell script that greps compiler stderr | A committed `.mpconf` that exercises the path and returns `{}` | Verified: an `.mpconf` whose `main()` returns `{}` writes **no** output file, so a negative test costs zero golden-file surface and runs as part of `make test`. This closes the gap `.planning/codebase/TESTING.md` names: "No negative tests: nothing asserts that a `fail()` path actually fires." |

**Key insight:** every mechanism FOUND-04 and FOUND-05 need already exists in the CI driver and is
already exercised by the reference stack. Both requirements are new *call sites* for existing
helpers, not new logic. The only genuinely new code in this phase is `SelectComponents` (12 lines),
a `WithLabels` hook (9 lines), and one workflow file.

## Runtime State Inventory

This phase changes generated artifacts and CI wiring, so the "what still holds the old value after
every file is updated?" question applies.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **None.** No database, no KV store, no `mutable_config/` directory in this repo. Terraform state itself lives in S3 (`platform-engineering-tfstate`) and *is* affected by the redis change — see the note below. | See note |
| Live service config | **None found in git-invisible config.** The only external service the repo configures is GitHub Actions, whose config *is* the committed workflow files. `vars.TF_PLAN_ROLE`, `vars.TF_APPLY_ROLE`, `vars.GRAFANA_WORKSPACE_ID` are repo-level GitHub variables referenced by the generated workflow — none of them change in this phase. | none |
| OS-registered state | **None.** No launchd/systemd/Task Scheduler/pm2 registration anywhere in the repo. | none |
| Secrets/env vars | **None changed.** The drift workflow needs **no secrets at all** — it compiles and diffs; it does not touch AWS, Grafana or Kubernetes. It should declare `permissions: contents: read` and nothing else. | none |
| Build artifacts | **`test/.protoconf_cache/`** — six symlinks plus six `.fds` files, gitignored (`.gitignore:48`, `.protoconf_cache`). On a developer machine each entry is a symlink into the repo (verified: `platform -> /Users/smintz/git/platform-engineering`), so local `.pinc` edits are live with no re-sync. On a runner it is absent and must be created by `mod tidy`. **`test/protoconf.lock`** — will be regenerated by `mod tidy` in CI with the runner's path; it must be excluded from the drift assertion. | drift workflow handles both; no developer action |

**Note on Terraform state (out of scope but must be said).** Giving Redis an S3 backend does not
migrate the state that already exists. Today `test/outputs/core_test/us-east-1/redis/infra` writes
`terraform.tfstate` on whatever disk ran the apply, and that state is already lost on every CI
apply — which is the bug FOUND-04 exists to catch. After the fix, the first apply against
`s3://platform-engineering-tfstate/us-east-1/redis.tfstate` starts from an empty state and will
plan to create the Kubernetes Deployment and Service. If a real cluster already has them, that
apply needs `terraform import` or a `-target`ed reconciliation. This is an operational
consequence, not a code change, and it belongs in the plan's notes rather than in a task.

## Common Pitfalls

### Pitfall 1: The committed lock's absolute path breaks the entire build off this machine

**What goes wrong:** `cd test && make test` exits 1 on a GitHub Actions runner, before it compiles
anything.

**Why it happens:** `test/protoconf.lock` commits a `getterUrl` per dependency, and it is an
absolute `file://` path. `[VERIFIED: test/protoconf.lock:9,17,25,33,41,49]` — the six committed
values, quoted verbatim:

```
"getterUrl":  "file:///Users/smintz/git/platform-engineering/drivers/runtime/ecs?ref=main",
"getterUrl":  "file:///Users/smintz/git/platform-engineering/drivers/cicd/github_actions?ref=main",
"getterUrl":  "file:///Users/smintz/git/platform-engineering/drivers/monitoring/grafana?ref=main",
"getterUrl":  "file:///Users/smintz/git/platform-engineering/drivers/runtime/kubernetes?ref=main",
"getterUrl":  "file:///Users/smintz/git/platform-engineering?ref=main",
"getterUrl":  "file:///Users/smintz/git/platform-engineering/drivers/state/terraform?ref=main",
```

I reproduced the runner condition by unpacking `git archive HEAD` at a foreign path and rewriting
that prefix to a path that does not exist. **Pasted failing output**, `protoconf mod sync`:

```
Downloading: ..
  => platform: Failed: stat /nonexistent/runner/work/platform-engineering: no such file or directory
Downloading: ../drivers/state/terraform
  => terraform_state: Failed: stat /nonexistent/runner/work/platform-engineering/drivers/state/terraform: no such file or directory
```
`SYNC_EXIT=1`

And `protoconf mod tidy` — note it does **not** fall back to the relative `url`:

```
  => platform: Failed: stat /nonexistent/runner/work/platform-engineering: no such file or directory
Downloading: ../drivers/runtime/kubernetes
  => kubernetes: Failed: stat /nonexistent/runner/work/platform-engineering/drivers/runtime/kubernetes: no such file or directory
Failed to sync protoconf.lock
```
`TIDY_EXIT=1`, and `grep getterUrl protoconf.lock` afterwards still shows the bogus path
unchanged. `protoconf compile .` then exits 1 on the empty cache.

**How to avoid:** `rm -f test/protoconf.lock` before `make test` in the drift workflow. Verified
working: with the lock absent, `protoconf mod tidy` regenerates it from `CONFIGSPACE`'s relative
urls (`TIDY_EXIT=0`), resolving `getterUrl` to the *current* checkout —

```json
"getterUrl": "file:///private/tmp/.../scratchpad/clone3/drivers/runtime/ecs?ref=main",
```

— symlinks `.protoconf_cache` correctly, and `protoconf compile .` then exits 0 and produces all
ten golden files byte-identically.

**Warning signs:** any `stat ...: no such file or directory` naming a path that is not the
runner's workspace.

**Two things this does NOT require:** it does not require changing the committed lock (the
deferred fix), and it does not require network access — every dependency in `CONFIGSPACE` is a
local relative path, so the whole build is hermetic and offline.

### Pitfall 2: `mod tidy`/`mod sync` rewrite `test/protoconf.lock` on every run

**What goes wrong:** A drift check that diffs the whole worktree fails on `test/protoconf.lock`
every single time, on a clean checkout, with no source change.

**Why it happens:** Two independent causes. (a) In CI the lock is deleted and regenerated, so its
`getterUrl` becomes the runner path. (b) Even locally, the two compilers disagree about JSON
whitespace: the committed lock (written by the developer's dev build) uses two spaces after each
colon, and the `v0.2.0-rc2` release binary writes one. Verified — running `mod tidy` with rc2 on
this machine produced a 44-line whitespace-only diff, with every `fileDescriptorSetSum` value
identical:

```
-  "url":  ".",
+  "url": ".",
```

**How to avoid:** Scope the diff to the three trees D-02 already names. `test/protoconf.lock` is
deliberately not among them.

**Warning signs:** a drift failure whose diff is entirely `protoconf.lock`.

### Pitfall 3: `git diff --exit-code` is blind to new files

**What goes wrong:** A contributor adds a component, which creates a *new* state directory under
`test/outputs/`. The new files are untracked. `git diff --exit-code` returns 0 and the drift check
passes green on exactly the drift it exists to catch.

**Why it happens:** `git diff` compares the index to the worktree for *tracked* paths only.
Verified in a scratch repo: with one untracked file present, `git diff --exit-code` returned 0
while `git status --porcelain` showed `?? untracked.txt`.

**How to avoid:** `git add -A -- <paths>` then `git diff --cached --exit-code -- <paths>`. Staging
first makes new files visible to the diff and still prints the human-readable diff on failure.

**Warning signs:** none — this failure is silent by construction, which is why it must be designed
out rather than watched for.

### Pitfall 4: `component.metadata` is `None` until you construct it

**What goes wrong:** `component.metadata.labels[k] = v` in a `WithLabels` hook raises at compile:

```
NoneType has no .labels field or method
Traceback (most recent call last):
  probe.mpconf:17:15: in main
```

**Why it happens:** proto3 message fields are unset until assigned. This is the same shape as the
existing guard in `Component` `[VERIFIED: src/platform/core.pinc:159-160]`:

```python
    if deps and not component.upstreams:
        component.upstreams = component_proto.Upstreams()
```

**How to avoid:** the identical two lines with `component_proto.Metadata()`. Verified working —
after constructing it, `labels` behaves like a Starlark dict: `[]=` assignment, `.get(k)`,
`.items()`, and `k in labels` all work (`LABELS: {"cost_center": "team-x"}`, `GET: team-x`,
`ITEMS: [("cost_center", "team-x")]`, `HAS_KEY: True`).

**Warning signs:** `NoneType has no .<field>` for any nested message field.

### Pitfall 5: Assuming proto messages are unhashable (they are not) — and assuming a diamond shares one object (it does not)

**What goes wrong:** Two opposite mistakes. Writing an elaborate identity scheme because "Starlark
messages can't be dict keys"; or writing `if c not in found: found.append(c)` on a list under the
belief that a diamond's repeated upstream is one shared object.

**Why it happens:** Both beliefs are wrong here, and they are wrong in a way that cancels out
neatly. Verified on a `top → {mid1, mid2} → leaf` graph:

```
DIAMOND_EQ: True
STR_EQ: True
L1_STR: "<platform.v1.Component name:\"leaf\" configs:<key:\"infra/main.tf.json\" value:<type_url:\"type.googleapis.com/terraform.v1.Terraform\">>>"
HASHABLE: True L2_IN: True
```

`mid1` and `mid2` each built their **own** `leaf` (`Component` calls `dep_factory(...)` once per
parent, `core.pinc:161-164`), so these are two distinct objects — and they compare equal and hash
equal. A `dict` therefore de-duplicates exactly the D-11 case. Also verified: `type(msg)` returns
the string `"platform.v1.Component"`, which is what `message_filter` compares.

**One consequence worth stating:** de-duplication is by *content*. Two components that differ in
nothing at all — same name, same domain, same configs — collapse to one. That is the intended
reading (they are indistinguishable), and components that differ in domain or in any hook do not
collapse.

**How to avoid:** use the dict. `found[c] = True` … `return found.keys()`. Verified to return a
Starlark `list` (`TYPE: list`), satisfying D-11's "returning a list".

### Pitfall 6: FOUND-05 reverses a deliberate existing tolerance

**What goes wrong:** The FOUND-05 check contradicts a comment that is currently in the file and
that argues, correctly, for the opposite behaviour. `[VERIFIED: drivers/cicd/github_actions/src/github_actions.pinc:108-111]`:

```python
# dependencies maps each config key to the keys of the configs whose state it reads. A
# state read from outside this set — a hand-written module, another repository — yields no
# edge: there is no job here to wait for, and pretending otherwise would be a lie about
# what the pipeline actually orders.
```

D-17 makes that same situation fatal. Both positions are defensible; D-17 is the locked one. But
leaving the comment in place after the behaviour changes leaves a driver whose prose argues
against its own code — precisely the kind of drift this phase exists to remove.

**How to avoid:** the plan must include updating that comment as part of the FOUND-05 task, not as
an afterthought. The honest replacement says the tolerance was traded away deliberately: reading a
state this pipeline does not apply is now an error because an unorderable read is worse than an
unsupported one.

**Warning signs:** none at compile time — this is a review-only concern.

### Pitfall 7: Expecting the redis fix to change the workflow

**What goes wrong:** The plan's verification says "expect a workflow diff", the workflow does not
change, and someone concludes the fix did not apply.

**Why it happens:** D-16 predicts "a consequent change to the generated pipeline's job ordering,
since a real backend gives Redis a state id that the ordering derivation can now match." The
premise is right and the conclusion does not follow: there is nothing to match *against*.
`[VERIFIED: test/outputs/core_test/us-east-1/*/*/main.tf.json — all four inspected]` **no config
in the reference stack declares a `terraform_remote_state` data source**; `data.terraform_remote_state`
is `null` in all four. `dependencies()` therefore returns empty upstream lists for every config
today, no `plan_*` job has a `needs:`, and giving Redis an S3 state id creates no edge because
nothing reads it.

**How to avoid:** state the expected diff exactly. See "The redis consequence" below.

**Warning signs:** a workflow diff *does* appear — that is the regression, and it means something
other than the backend changed.

## Code Examples

### 1. The drift workflow (verified recipe, YAML is the planner's discretion)

Every step below was executed against a clean `git archive HEAD` unpacked at an unrelated path.

```yaml
# .github/workflows/drift.yaml — hand-written on purpose (D-01): the artifact this checks
# is the generated pipeline, so a generated checker could be omitted by the staleness it
# exists to catch.
name: drift
on:
  pull_request:
    paths: [test/src/**, src/**, drivers/**, test/CONFIGSPACE, test/protoconf.lock]
  push:
    branches: [main]
    paths: [test/src/**, src/**, drivers/**, test/CONFIGSPACE, test/protoconf.lock]
  workflow_dispatch: {}

permissions:
  contents: read          # compiles and diffs; touches no cloud, needs no secret

jobs:
  compile:
    runs-on: ubuntu-latest
    env:
      PROTOCONF_VERSION: 0.2.0-rc2
      PROTOCONF_SHA256: eeb8415960567e23f1a3a4acb8eb28a07cb68a544c4c2e3fd41fb7ebdfde9f3a
    steps:
      - uses: actions/checkout@v4

      - name: install protoconf
        run: |
          curl -fsSL -o /tmp/protoconf.tar.gz \
            "https://github.com/protoconf/protoconf/releases/download/v${PROTOCONF_VERSION}/protoconf_${PROTOCONF_VERSION}_linux_amd64.tar.gz"
          echo "${PROTOCONF_SHA256}  /tmp/protoconf.tar.gz" | sha256sum -c -
          sudo tar -xzf /tmp/protoconf.tar.gz -C /usr/local/bin protoconf
          protoconf --version

      # The committed lock pins each module by an absolute file:// path from the machine
      # that last ran `mod tidy`. That path does not exist here, and `mod tidy` does not
      # fall back to the relative url in CONFIGSPACE — it fails. Deleting the lock makes
      # tidy re-resolve against this checkout. The lock is deliberately outside the diff
      # asserted below, so regenerating it proves nothing and breaks nothing.
      - name: drop the machine-local lock
        run: rm -f test/protoconf.lock

      - name: rebuild
        run: cd test && make test

      # `git diff` alone cannot see a NEW output file — a new component would add an
      # untracked state directory and pass green. Staging first makes additions visible.
      - name: assert generated output is current
        run: |
          git add -A -- test/materialized_config test/outputs .github/workflows/terraform.yaml
          git diff --cached --exit-code -- \
            test/materialized_config test/outputs .github/workflows/terraform.yaml \
          || {
            echo "::error::generated output is stale. Run 'cd test && make test' and commit the result."
            exit 1
          }
```

### 2. Reproducibility transcript — the release binary reproduces the goldens byte for byte

This is the evidence behind the D-04 pin. `git archive HEAD` was unpacked at
`/private/tmp/.../scratchpad/clone3`, its lock deleted, and the public `v0.2.0-rc2` binary run:

```
TIDY_EXIT=0
COMPILE_EXIT=0
OK test/materialized_config/core_test/.github/workflows/terraform.yaml.materialized_JSON
OK test/materialized_config/core_test/us-east-1/api-task/infra/main.tf.json.materialized_JSON
OK test/materialized_config/core_test/us-east-1/api-task/monitoring/main.tf.json.materialized_JSON
OK test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON
OK test/materialized_config/core_test/us-east-1/redis/monitoring/main.tf.json.materialized_JSON
OK test/outputs/core_test/.github/workflows/terraform.yaml
OK test/outputs/core_test/us-east-1/api-task/infra/main.tf.json
OK test/outputs/core_test/us-east-1/api-task/monitoring/main.tf.json
OK test/outputs/core_test/us-east-1/redis/infra/main.tf.json
OK test/outputs/core_test/us-east-1/redis/monitoring/main.tf.json
```

Run-to-run determinism, three clean rebuilds, hashing the sorted hash of every generated file:

```
2be75d75aefc68cce292d1a2376027621828ed22b57b7203b84351c319161704  -
2be75d75aefc68cce292d1a2376027621828ed22b57b7203b84351c319161704  -
2be75d75aefc68cce292d1a2376027621828ed22b57b7203b84351c319161704  -
```

Also verified: a missing `.protoconf_cache` makes `protoconf compile .` exit **1** with
`try run 'protoconf mod sync'` — so a broken CI setup fails loudly rather than emitting nothing.

### 3. `WithLabels` — FOUND-02 (verified working)

```python
# WithLabels declares the shape of a component: the keys a policy, a cost centre or a
# hardening rule selects on later. It is Metadata.labels rather than Metadata.tags because
# one keyed vocabulary can answer "which components matched, and on what value"; a bare tag
# set cannot, and two vocabularies answering the same question can disagree.
def WithLabels(**labels):
    def do(component, next):
        # proto3 nested messages are unset until assigned, the same reason Component
        # constructs Upstreams before appending to it
        if not component.metadata:
            component.metadata = component_proto.Metadata()
        for key, value in labels.items():
            component.metadata.labels[key] = value
        return next(component)

    return component_filter(do)
```

Belongs in `src/platform/core.pinc` (it is driver-agnostic and `component_proto` is already
loaded there at line 1), exported through the facade beside `WithDescription`.

**Note for Phase 2 (COST-01), not for this phase:** COST-01 requires a cost centre to propagate
to a component's whole dependency subtree. That is what the existing `Inherit` marker does, and
`WithFailureDomain` `[VERIFIED: src/platform/core.pinc:121-126]` is the exact precedent —
it returns `Inherit(component_filter(do))`. Whether `WithLabels` should inherit is a Phase 2
decision; keep it non-inheriting here (D-09 asks for an ordinary `component_filter` hook) and let
Phase 2 add an inheriting variant if it needs one.

### 4. `SelectComponents` — FOUND-03 (verified working, golden-clean)

Applied to `src/platform/core.pinc`, replacing the nested closure at lines 205-210 with a call:

```python
# walk_upstreams visits every component in the graph depth-first, upstreams before the
# component that declared them, and hands each one to `next`. Module level rather than
# nested in GetConfigs because SelectComponents needs the same order: two traversals are
# two things that can disagree about what the graph is.
def walk_upstreams(component, next):
    if not component.upstreams:
        return next(component)
    for upstream in component.upstreams.components:
        walk_upstreams(upstream, next)
    return next(component)

# SelectComponents returns every component in the graph rooted at `component` that
# `predicate` accepts, in the same post-order walk_upstreams produces, de-duplicated: a
# component reached down two arms of a diamond is one component, and a policy hook applied
# to it twice is applied once too often. Messages hash and compare by value here, so the
# dict does the de-duplication — the two arms hold two distinct objects with equal content,
# which is exactly the case identity comparison would miss.
def SelectComponents(component, predicate):
    found = {}

    def collect(c):
        if predicate(c):
            found[c] = True

    walk_upstreams(component, collect)
    return found.keys()

def GetConfigs(component):
    configs = {}

    def collect_configs(component):
        ...                       # unchanged
    walk_upstreams(component, collect_configs)   # was: the nested def, then this call
    return configs
```

**Placement warning:** `GetConfigs`' four-line doc comment currently sits directly above
`def GetConfigs`. Inserting the new functions above `GetConfigs` will orphan that comment onto
`walk_upstreams` unless the insertion goes *above the comment*. My scratch patch made exactly this
mistake; it compiles fine and reads wrong.

Facade export (`src/platform/platform.pinc`) — one line in the `load(...)` list and one in the
struct, keeping both alphabetically placed:

```python
load(
    "//platform/core.pinc",
    ...
    "MAIN_CONFIG",
    "SelectComponents",
    ...
)

platform = struct(
    ...
    GetConfigs = GetConfigs,
    SelectComponents = SelectComponents,
    ...
)
```

**Verified behaviour** on `top → {mid1, mid2} → leaf` with labels `edge`/`app`/`app`/`cache`:

```
ALL: ["leaf", "mid1", "mid2", "top"] TYPE: list
APPS: ["mid1", "mid2"]
CACHES: ["leaf"]
NONE: []
CONFIG_KEYS: ["d1/leaf/infra/main.tf.json"]
```

`leaf` appears once (de-dup works), order is post-order, an empty match returns `[]` rather than
failing — which SEC-02 in Phase 5 will need in order to raise its own error.

**Verified D-12:** after this refactor, recompiling the reference stack left **all ten** golden
files byte-identical.

**Predicate calling convention (Claude's discretion, D-11):** the predicate receives the
`platform.v1.Component` **message**, not the `module` wrapper — `walk_upstreams` yields messages,
because `upstreams.components` holds messages. Root argument is likewise a message, matching
`GetConfigs(component.msg)` at `test/src/core_test.mpconf:112-114`. Recommend `SelectComponents(root_msg, predicate)`.

### 5. FOUND-04 — `_check_remote_backends` (verified firing on redis)

```python
# Every config here gets an apply job, and an apply runs on a runner whose disk is thrown
# away when the job ends. A local backend on such a state is not a smaller choice, it is a
# state that never persists: each apply plans against nothing and recreates everything.
# Terraform says nothing about it and GitHub says nothing about it, so it is said here.
def _check_remote_backends(configs):
    for key in sorted(configs.keys()):
        config = configs[key]
        backend = config.terraform.backend if config.terraform else None
        if not backend:
            fail(
                ("TerraformPipeline: %s has no Terraform backend, and CI applies it on a " +
                 "runner whose disk is discarded when the job ends. Pass a backend as the " +
                 "second argument to WithState(...) for this component.") % _dir(key),
            )
        if backend.local:
            fail(
                ("TerraformPipeline: %s writes local Terraform state, and CI applies it on " +
                 "a runner whose disk is discarded when the job ends — every apply would " +
                 "start from an empty state. Pass BACKEND as the second argument to " +
                 "WithState(...) for this component.") % _dir(key),
            )
```

Called from `TerraformPipeline` immediately before `deps = dependencies(configs)`. **Pasted real
output** compiling the unmodified reference stack with this in place:

```
Error compiling config /core_test.mpconf:
    error evaluating starlark file
[@github_actions//github_actions.pinc:585:17] TerraformPipeline: us-east-1/redis/infra writes local Terraform state, and CI applies it on a runner whose disk is discarded when the job ends — every apply would start from an empty state. Pass BACKEND as the second argument to WithState(...) for this component.
Traceback (most recent call last):
  core_test.mpconf:121:76: in main
  @github_actions//github_actions.pinc:637:27: in TerraformPipeline
  @github_actions//github_actions.pinc:585:17: in _check_remote_backends
```

Two implementation notes. **Use `_dir(key)` for the label, not a slice of `key`.** The config key
is `"<domain>/<name>/<config path>"`, and the domain is omitted when empty
`[VERIFIED: src/platform/core.pinc:188 — `prefix = "/".join([p for p in (component.domain, component.name) if p])`]`,
so `key.split("/")[1]` is the component name only when a domain exists. `_dir(key)` is what every
other message in this driver uses (`"plan %s" % label`). **`backend.local` is truthy for an empty
`BackendLocal`** — the redis config renders `"backend": {"local": {}}` and the check fired, so no
extra emptiness test is needed.

### 6. FOUND-05 — `_producers` + `_check_reads_are_produced` (verified both ways)

Extract the producer map that `dependencies()` builds today, leaving `dependencies()`' exported
signature untouched:

```python
def _producers(configs):
    producer = {}
    for key in sorted(configs.keys()):
        state = _backend_state_id(configs[key])
        if not state:
            continue

        # Two configs pointing at one state is not a pipeline the driver can order: their
        # applies would race for the same lock, and whichever landed second would plan
        # against a state the other had already moved. It is silent in Terraform and
        # silent in GitHub, so it has to be loud here.
        if state in producer:
            fail(
                "%s and %s both write the Terraform state %s" %
                (producer[state], key, state),
            )
        producer[state] = key
    return producer

def dependencies(configs):
    producer = _producers(configs)
    deps = {}
    ...                          # rest unchanged

# A terraform_remote_state pointing at a state no config here writes is invisible to the
# ordering derivation above: the read produces no edge, so the pipeline is free to apply
# the reader before whatever writes that state. The apply order that results is not wrong
# by a little, it is arbitrary — so the handshake has to be one this pipeline can see.
def _check_reads_are_produced(configs):
    producer = _producers(configs)
    for key in sorted(configs.keys()):
        for state in _reads(configs[key]):
            if state and state in producer:
                continue
            fail(
                ("TerraformPipeline: %s reads the Terraform state %s, which no config in " +
                 "this pipeline writes, so nothing orders the read after the write. Give " +
                 "the publishing component a backend this pipeline also applies, or pass " +
                 "the same backend to both halves of the handshake.") %
                (_dir(key), state or "(a backend this driver cannot name)"),
            )
```

**Verified both directions** on a `sub → pub` pair where both use `WithState(..., BACKEND)` and
`pub` publishes with `WithRemoteOutput("host", "pub.internal", <handshake backend>)`.

Correct handshake (same backend on both halves) — the check is silent and, importantly, the
ordering edge the DB driver will need in Phase 3 (DATA-05) is derived:

```
GOOD_DEPS: {"d1/pub/infra/main.tf.json": [], "d1/sub/infra/main.tf.json": ["d1/pub/infra/main.tf.json"]}
GOOD: pipeline built
```

Mismatched handshake (`WithRemoteOutput` handed a *different* bucket than the publisher's
`WithState`) — the exact silent-wrong-order bug FOUND-05 exists for:

```
Error compiling config /probe.mpconf:
    error evaluating starlark file
[@github_actions//github_actions.pinc:602:17] TerraformPipeline: d1/sub/infra reads the Terraform state s3://somebody-elses/d1/pub.tfstate, which no config in this pipeline writes, so nothing orders the read after the write. Give the publishing component a backend this pipeline also applies, or pass the same backend to both halves of the handshake.
```

Also note: `_reads` can yield `None` for a backend the driver cannot name
`[VERIFIED: drivers/cicd/github_actions/src/github_actions.pinc:98 — `return None` closing `_remote_state_id`]`.
The `if state and state in producer` guard catches both `None` and "not produced" in one branch,
and the `state or "(...)"` in the message keeps the error readable in the `None` case.

### 7. The redis consequence — exactly which golden files change

**Confirmed at the call site** `[VERIFIED: test/src/core_test.mpconf:50]`, quoted verbatim:

```python
        WithState(lambda component: Workload("redis", "redis:7-alpine", 6379)),
```

— second positional argument absent, so `WithState`'s `backend = backend or DEFAULT_BACKEND`
`[VERIFIED: drivers/state/terraform/src/terraform.pinc:170-171]` selects
`DEFAULT_BACKEND = LocalBackend()` `[VERIFIED: drivers/state/terraform/src/terraform.pinc:129]`.

**`BACKEND` at that call site** `[VERIFIED: test/src/core_test.mpconf:9-13]`, verbatim:

```python
BACKEND = S3Backend(
    "platform-engineering-tfstate",
    "us-east-1",
    lambda domain, name: "%s/%s.tfstate" % (domain, name),
)
```

**The fix** is one argument:

```python
        WithState(lambda component: Workload("redis", "redis:7-alpine", 6379), BACKEND),
```

**The expected diff — exactly two files, and no others.** Verified by applying the fix in a clone
and byte-comparing every golden file:

```
DIFF test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON
DIFF test/outputs/core_test/us-east-1/redis/infra/main.tf.json
(all eight others: OK)
```

`test/outputs/core_test/us-east-1/redis/infra/main.tf.json`:

```diff
     "backend": {
-      "local": {
-
+      "s3": {
+        "region": "us-east-1",
+        "bucket": "platform-engineering-tfstate",
+        "key": "us-east-1/redis.tfstate"
       }
     }
```

`test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON`:

```diff
       "backend": {
-        "local": {}
+        "s3": {
+          "region": "us-east-1",
+          "bucket": "platform-engineering-tfstate",
+          "key": "us-east-1/redis.tfstate"
+        }
       }
```

**`.github/workflows/terraform.yaml` and `test/outputs/core_test/.github/workflows/terraform.yaml`
do NOT change.** See Pitfall 7. This corrects D-16.

### 8. Optional: the negative test that proves the guards fire

`.planning/codebase/TESTING.md` records "No negative tests: nothing asserts that a `fail()` path
actually fires", and both FOUND-04 and FOUND-05 are `fail()` paths whose whole value is firing.
An `.mpconf` returning `{}` writes no output file (verified — a probe returning `{}` produced no
entries under `outputs/` or `materialized_config/`), so a positive-path assertion costs nothing:

```python
# test/src/select_test.mpconf — compiled by `make test`, materializes nothing.
# Asserts what the golden files cannot: Component.Metadata.labels round-trips, and
# SelectComponents de-duplicates a diamond instead of returning the shared leaf twice.
def main():
    ...
    names = [c.name for c in platform.SelectComponents(root, HasLabel("tier", "cache"))]
    if names != ["leaf"]:
        fail("SelectComponents: expected ['leaf'], got %s" % names)
    return {}
```

The FOUND-04/05 `fail()` paths cannot be asserted this way in-process — Starlark has no way to
catch a `fail()`. Their proof is the transcripts in §5 and §6 above, reproduced once by hand
during execution. Recommend the planner make that a one-line manual verification step
("temporarily drop `BACKEND` from redis, confirm the named error, restore") rather than trying to
automate it.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No CI job compiles the source; the pipeline plans the *committed* output | A hand-written drift workflow compiles and asserts | this phase | Closes the gap `.planning/codebase/TESTING.md` calls "the largest gap in the current setup" |
| `_backend_state_id` returns `None` for unknown backends and a `None` costs an edge (silently) | Unchanged for unknown backends; but a *known* local backend, and an *unproduced* read, now `fail()` | this phase (FOUND-04/05) | Narrows "return None rather than a wrong answer" to the cases where an edge is genuinely optional |
| A read pointing outside the pipeline is tolerated | It is fatal (D-17) | this phase | Makes the near/far handshake convention enforceable for phases 3-5; see Pitfall 6 |
| `Component.Metadata.labels` declared but written by nothing | Populated by `WithLabels`, selectable via `SelectComponents` | this phase | Unblocks COST-01/02/03 and SEC-01/02/03 |

**Deprecated/outdated:**
- The root `outputs/` and `materialized_config/` trees: unreachable from any source, deleted by
  D-05.
- `.planning/research/SUMMARY.md`'s proposal to add `Component.tags`: superseded by D-07 — the
  field exists as `Component.Metadata.labels`.
- D-16's prediction of a workflow-ordering diff: corrected by measurement (Pitfall 7).

## Project Constraints (from CLAUDE.md)

`./.claude/CLAUDE.md` (the configured `claude_md_path`). Directives that bind this phase:

| Directive | Bearing on Phase 1 |
|-----------|--------------------|
| "The module graph must stay acyclic — drivers load `@platform`, the platform layer loads no driver, and drivers never load each other" | `SelectComponents` goes in `core.pinc` and is exported by `platform.pinc`, which already loads `core.pinc`. No new load edge. Satisfied by construction. |
| "Hook ordering is load-bearing — main config mutates before the component chain; inherited hooks run before local ones" | `WithLabels` is an ordinary `component_filter` hook and does not touch configs, so it is order-insensitive. Do not make it a marker (also D-09). |
| "Credentials never appear in configuration — CI mints them (OIDC, short-lived tokens)" | The drift workflow needs **no** credentials. Give it `permissions: contents: read` and nothing else. Do not copy the generated pipeline's OIDC block into it. |
| "Fail at compile time in Starlark with a message naming the fix; return `None` rather than a wrong answer" | Exactly D-18. Both new messages name the argument (`BACKEND` to `WithState(...)`) and the component, matching the tone of the existing job-id `fail()`. |
| "Every value the platform produces must be expressible as a proto message" | `labels` is `map<string,string>` — string values only. A cost centre or a policy selector value must be a string; no nested structure. |
| GSD workflow enforcement: "Do not make direct repo edits outside a GSD workflow" | Research made no repo edits. Every experiment ran against `git archive` copies in the scratchpad, except one deliberately reverted probe; `git status` is clean. |

**From `.claude/skills/protoconf-dev/SKILL.md`** (invoke before writing any `.pinc`/`.proto`):
- `.pinc` files are libraries and materialize nothing; only `.mpconf`/`.pconf` produce output.
- `load()` paths are rooted at `src/` and use `//` for the local module root.
- Formatting is `black` via `protoconf fmt -w`; the repo's root `make fmt` does this.
- `print(...)` goes to stderr at compile time — **remove before committing** (relevant: the
  execution loop for FOUND-02/03 will want prints, and they must not survive into a commit).
- "Refactor validation: compile then `git diff materialized_config/ outputs/` — if the diff is
  empty, the refactor is behavior-preserving." That is D-12's verification verbatim.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The `linux_amd64` release binary produces byte-identical output to the `darwin_arm64` one I tested. | Standard Stack, Code Examples 2 | The first drift-check run fails with a diff nobody introduced. Cheap to detect and cheap to diagnose (the diff will be uniform and unrelated to the PR). Mitigation: make the first CI run of the new workflow an explicit verification step in the plan, on a no-op PR, before relying on it. I verified byte-reproducibility on darwin/arm64 across three clean rebuilds and across two different builds of the compiler, and the driver sorts every map it iterates — but I cannot run linux here. |
| A2 | `ubuntu-latest` GitHub-hosted runners are x86-64, so `linux_amd64` is the right asset. | Standard Stack | The install step fails immediately and loudly with an exec-format error. Trivially diagnosed. |
| A3 | No secret or repo variable is needed by the drift workflow. | Project Constraints, Code Examples 1 | If wrong, the workflow fails on a missing value. The build is entirely local — no network beyond the one pinned download, and every `remote_repo` in `CONFIGSPACE` is a relative path — so this is low risk. |
| A4 | `sudo tar -xzf ... -C /usr/local/bin` works unprompted on `ubuntu-latest`. | Standard Stack | The install step fails. Passwordless sudo is standard on GitHub-hosted runners; if the planner prefers to avoid it, extract to `$HOME/.local/bin` and add it to `$GITHUB_PATH`. |
| A5 | `protoconf v0.2.0-rc2` will remain the newest release for the life of this phase, so the pin does not immediately go stale. | Standard Stack | Only a freshness concern; the pin is the point and a newer release changes nothing until someone bumps it deliberately. |

## Open Questions (RESOLVED)

1. **Should the drift check also assert the `test/protoconf.lock` is coherent?**
   - What we know: D-03 lists `test/protoconf.lock` among the *triggers*, and D-02 excludes it
     from the *assertion*. The recipe above deletes it. So a PR that corrupts the lock triggers
     the check, and the check then throws the lock away and passes.
   - What's unclear: whether that is intended. The `fileDescriptorSetSum` values in the lock are
     genuinely meaningful — they would catch a `.proto` change that nobody re-tidied.
   - RESOLVED: accept it for this phase. Asserting on the lock requires either fixing the
     absolute-path problem properly (a protoconf-side change, explicitly deferred) or a
     normalisation step that would itself need testing. Note it in Deferred beside the existing
     absolute-path item, now with the CI consequence attached.

2. **Does FOUND-05 need an escape hatch for a genuinely external state?**
   - What we know: D-17 makes any unproduced read fatal, reversing the tolerance documented at
     `github_actions.pinc:108-111`. Nothing in the reference stack reads an external state today,
     so nothing breaks now.
   - What's unclear: whether a future component will legitimately read a state applied by a
     different repository.
   - RESOLVED: build it with no escape hatch (YAGNI, and D-17 is locked). If phases 3-5 hit
     the case, the hatch is a one-argument addition to `TerraformPipeline`
     (`external_states = []`). Do not build it speculatively.

3. **Where should `WithLabels` live, and is one needed at all?**
   - What we know: D-09 says none is *required*; FOUND-02 says a component must *carry* key/value
     tags. Carrying them requires some way to write them.
   - What's unclear: whether the planner reads FOUND-02 as "the field exists and is writable" (no
     hook — a call site could assign `component.metadata` through a bespoke hook) or "there is a
     supported way to declare them" (a hook).
   - RESOLVED: add `WithLabels` to `core.pinc` and export it. It is nine lines, it is the
     established idiom, and every one of COST-01, COST-02, SEC-01 needs it in the next two phases.
     Without it FOUND-02 has no observable surface at all.

4. **Does the redis backend change need a state migration before the next apply?**
   - What we know: the new S3 state starts empty; any Kubernetes objects that already exist will
     be planned for creation.
   - What's unclear: whether a real cluster currently holds them.
   - RESOLVED: out of scope for the code change, but the plan should carry it as an
     operational note so nobody is surprised by the first post-merge plan.

## Environment Availability

Probed on the development machine this session.

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `protoconf` (dev build) | Local verification loop | ✓ | reports `0.0.1`; built from `github.com/protoconf/protoconf v0.2.0-rc2.0.20260907140707-57725ef97de6+dirty` on `origin/perf/compiler` | Use the pinned `v0.2.0-rc2` release binary — verified to produce identical output |
| `protoconf v0.2.0-rc2` release | Drift workflow (CI) | ✓ | `0.2.0-rc2`, sha256-verified | none needed |
| `git` | Drift assertion | ✓ | 2.50.1 (Apple Git-155) | — |
| `make` | `cd test && make test` | ✓ | present | — |
| `terraform` | **Not required by this phase** | ✓ | v1.13.4 locally (CI pins 1.9.8 for applies) | — |
| `go` | Only if `go install` is chosen over the tarball | ✓ | go1.25.1 darwin/arm64 | tarball, recommended |
| `gh` | Not required | ✓ | present | — |
| Network access at compile time | none | n/a | — | Every `CONFIGSPACE` dep is a local relative path; the build is hermetic and offline |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** none.

**One environment fact the planner must know.** `test/.protoconf_cache/<label>` entries are
**symlinks into the working tree** on a developer machine — verified:

```
platform -> /Users/smintz/git/platform-engineering
github_actions -> /Users/smintz/git/platform-engineering/drivers/cicd/github_actions
...
```

so an **uncommitted** edit to `src/platform/core.pinc` or to any driver is picked up by
`protoconf compile .` immediately, with no `mod tidy`. I confirmed this by appending a constant to
`core.pinc` without committing and loading it from a probe: `PROBE_MARKER: yes`. The tight
execution loop is therefore just `cd test && protoconf compile .` — no re-sync needed between
edits.

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1` (`.planning/config.json`).

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | The drift workflow authenticates to nothing. The generated pipeline's OIDC role assumption is unchanged by this phase. |
| V3 Session Management | no | No sessions. |
| V4 Access Control | yes | `permissions: contents: read` on the drift workflow, and nothing more. It must not inherit `id-token: write` or `pull-requests: write`. |
| V5 Input Validation | yes | This phase *is* input validation, at the config layer: FOUND-04 and FOUND-05 are compile-time rejections of configurations that cannot be honoured. `fail()` at compile is the repo's stated mechanism. |
| V6 Cryptography | yes (supply chain) | The `protoconf` binary is pinned by version **and** sha256, verified against the publisher's `checksums.txt`. Do not replace with an unpinned `latest` or an unverified `curl \| sh`. |
| V14 Configuration | yes | Pinned action versions (`actions/checkout@v4`, matching the repo's existing pin); no secrets in the new workflow; the new workflow runs only on `pull_request`, `push` to main, and `workflow_dispatch` — never `pull_request_target`. |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Untrusted PR code executes with repository write scope | Elevation of Privilege | Use `pull_request`, **never** `pull_request_target`. The drift workflow runs contributor-authored Starlark through a compiler, so it must have no privileged token. `permissions: contents: read`. |
| Supply-chain substitution of the compiler binary | Tampering | sha256 pin verified against the publisher's `checksums.txt` (both values recorded in §Standard Stack). |
| Mutable action tags | Tampering | `actions/checkout@v4` matches the repo's existing convention. A SHA pin would be stronger; note it and keep consistency for now. |
| Terraform state lost on every apply (the FOUND-04 bug) | Denial of Service / Tampering | This is the live instance: redis state is discarded each apply, so every apply recreates or fights over the deployment. FOUND-04 makes it a compile error. |
| Wrong or partial apply order from an invisible cross-state read | Tampering | FOUND-05 — a read the pipeline cannot order is now fatal rather than silently unordered. |
| Username leaked in a committed file | Information Disclosure | `test/protoconf.lock` commits `/Users/smintz/...` six times. Low severity, already in Deferred; unchanged by this phase (CI deletes the lock rather than rewriting the committed copy). |
| Plan artifacts containing resolved secrets | Information Disclosure | Existing control, untouched: 5-day retention on `tfplan` artifacts (`github_actions.pinc:462`). |

## Sources

### Primary (HIGH confidence)

- **The repository itself, read this session:** `src/platform/core.pinc`, `src/platform/platform.pinc`,
  `src/platform/v1/platform.proto`, `drivers/cicd/github_actions/src/github_actions.pinc`,
  `drivers/state/terraform/src/terraform.pinc`, `test/src/core_test.mpconf`, `test/Makefile`,
  `test/CONFIGSPACE`, `test/protoconf.lock`, `.gitignore`, `.gitattributes`, all four generated
  `main.tf.json` files, and the generated `terraform.yaml`.
- **Executed experiments (this session, against `git archive HEAD` copies in the scratchpad):**
  release-binary reproducibility; three-run determinism; foreign-path build; absolute-path lock
  failure and its fix; proto message hashability and structural equality; `metadata` nil
  behaviour; the `SelectComponents` refactor with a golden-diff check; the FOUND-04 and FOUND-05
  checks with both firing and silent cases; the redis `BACKEND` fix and its exact diff;
  `git diff --exit-code` untracked-file blindness.
- **`github.com/protoconf/protoconf` GitHub Releases API and `checksums.txt`** — release list,
  asset names and sizes, and the sha256 of the artifact actually downloaded.
- **`go version -m ~/go/bin/protoconf`** — module path and the provenance of the local dev build.

### Secondary (MEDIUM confidence)

- `.planning/codebase/{TESTING,ARCHITECTURE,CONVENTIONS,STACK}.md` — used for intent and
  vocabulary. Where they disagreed with the source, the source won: TESTING.md states the
  reference scenario covers "Cross-state reads (S3 backend + `terraform_remote_state`)", but no
  committed config declares a `terraform_remote_state` (Pitfall 7).
- `.claude/skills/protoconf-dev/SKILL.md` — compile-loop and output-mapping mechanics.

### Tertiary (LOW confidence)

- None. Every claim in this document is either read from a file in this repo, or produced by a
  command I ran and whose output is pasted above.

## Metadata

**Confidence breakdown:**
- Standard stack: **HIGH** — the pinned version, its checksum and its behaviour against this exact
  repository were all measured, not looked up.
- Architecture: **HIGH** — all four code changes were implemented and compiled against the real
  reference stack; the golden-file consequences were measured file by file.
- Pitfalls: **HIGH** — every pitfall listed is one I hit or deliberately reproduced, with output
  pasted. The one residual gap is cross-platform reproducibility (A1), flagged as `[ASSUMED]`.

**Research date:** 2026-09-07
**Valid until:** 2026-10-07 for the in-repo findings (they change only when the repo does); 7 days
for the `protoconf` release pin, which is a fast-moving pre-1.0 project currently on release
candidates.
