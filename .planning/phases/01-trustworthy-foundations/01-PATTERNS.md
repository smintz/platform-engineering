# Phase 1: Trustworthy Foundations - Pattern Map

**Mapped:** 2026-09-07
**Files analyzed:** 6 (4 modified `.pinc`/`.mpconf`, 1 new workflow YAML, 2 deleted trees)
**Analogs found:** 5 / 6

All analog paths below verified git-TRACKED via `git ls-files`. No gitignored mirror paths.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `src/platform/core.pinc` — lift `walk_upstreams`, add `SelectComponents` | platform core / traversal | transform (graph → list) | same file: `GetConfigs` (lines 184-214) and the `chain`/`flatten` module-level plumbing (lines 5-28) | exact |
| `src/platform/core.pinc` — add `WithLabels` | hook factory | transform (message mutation) | same file: `WithDescription` (101-107), `WithFailureDomain` (118-126), and the `Upstreams()` nil-guard (159-160) | exact |
| `src/platform/platform.pinc` — export `SelectComponents` (+ `WithLabels`) | facade / re-export | n/a | the whole file — every symbol already follows one shape (load list + struct field) | exact |
| `drivers/cicd/github_actions/src/github_actions.pinc` — `_producers`, `_check_remote_backends`, `_check_reads_are_produced` | driver / compile-time validation | transform + guard | same file: job-id collision `fail()` (599-604), duplicate-state `fail()` inside `dependencies` (112-129), `_backend_state_id`/`_remote_state_id`/`_reads` (50-107) | exact |
| `test/src/core_test.mpconf:50` — pass `BACKEND` to redis `WithState` | call site | config declaration | same file: `ApiTaskComponent`'s `WithState` at lines 78-81 | exact |
| `.github/workflows/drift.yaml` (NEW, hand-written) | CI config | request-response (CI job) | **none** — see §No Analog Found | none |
| root `outputs/`, `materialized_config/` (DELETED, D-05) | generated artifacts | n/a | n/a — `git rm -r` only | n/a |

## Pattern Assignments

### `src/platform/core.pinc` — `walk_upstreams` + `SelectComponents` (FOUND-03)

**Analog:** `src/platform/core.pinc` itself. `GetConfigs` (184-214) currently owns the closure; the
module-level `chain`/`flatten`/`message_filter` block (5-54) is the shape a lifted helper takes.

**Current state — the closure to lift** (lines 205-212, verbatim):

```python
    def walk_upstreams(component, next):
        if not component.upstreams:
            return next(component)
        for upstream in component.upstreams.components:
            walk_upstreams(upstream, next)
        return next(component)

    walk_upstreams(component, collect_configs)
```

**Target shape:** RESEARCH.md §Code Examples 4 contains the verified implementation (module-level
`walk_upstreams`, then `SelectComponents(component, predicate)` collecting into a `dict` and
returning `found.keys()`). Use it verbatim; do not re-derive. It was compiled against the reference
stack and left all ten golden files byte-identical (D-12).

**Comment convention to copy** — every module-level function here carries a `#` block above the
`def` explaining *why*, not what (`chain` is the exception; see `message_filter` 30-31,
`WithDeps` 63-65, `Finally` 75-78, `GetConfigs` 180-183). New functions need the same.

**Placement warning (RESEARCH.md §Code Examples 4):** `GetConfigs`' 4-line doc comment sits
directly above `def GetConfigs` at 180-183. Insert the new functions **above that comment**, not
between it and the `def`, or the comment orphans onto `walk_upstreams`.

**`next`-callback convention:** `walk_upstreams` takes `(component, next)` matching every hook in
this file. Keep it — `SelectComponents` passes a `collect` closure, exactly as `GetConfigs` passes
`collect_configs`.

---

### `src/platform/core.pinc` — `WithLabels` (FOUND-02, D-09)

**Analog:** `WithDescription` at lines 101-107 (closest — plain `component_filter`, no `Inherit`):

```python
# WithDescription sets the component's human-readable description.
def WithDescription(description):
    def do(component, next):
        component.description = description
        return next(component)

    return component_filter(do)
```

**Contrast analog — `WithFailureDomain`** (118-126) shows the *inheriting* variant, ending
`return Inherit(component_filter(do))`. D-09 says ordinary `component_filter`, so copy
`WithDescription`'s ending, **not** this one. (RESEARCH.md flags inheritance as a Phase 2 question.)

**Nil-guard pattern to copy** — `Component` at 159-160, the precedent for constructing an unset
nested proto message before writing into it (Pitfall 4: `component.metadata` is `None` until
assigned):

```python
    if deps and not component.upstreams:
        component.upstreams = component_proto.Upstreams()
```

`component_proto` is already loaded at line 1 (`load("//platform/v1/platform.proto", component_proto = "Component")`),
so `component_proto.Metadata()` needs no new load.

**Body:** RESEARCH.md §Code Examples 3 has the verified 9-line implementation.

---

### `src/platform/platform.pinc` — facade export (D-13)

**Analog:** the file itself, 72 lines, one shape throughout.

**Load-list pattern** (lines 1-21) — alphabetically sorted, `PascalCase` before `snake_case`:

```python
load(
    "//platform/core.pinc",
    "CONFIG_TYPES",
    "Component",
    ...
    "MAIN_CONFIG",
    "TerraformConfig",
    "WithConfig",
    ...
)
```

`"SelectComponents"` slots between `"MAIN_CONFIG"` and `"TerraformConfig"`; `"WithLabels"` between
`"WithFailureDomain"` and `"chain"`.

**Struct pattern** (42-72) — grouped by `# comment` sections, **not** alphabetical within a group:

```python
platform = struct(
    ...
    # components and their configs
    Component = Component,
    GetConfigs = GetConfigs,
    MAIN_CONFIG = MAIN_CONFIG,
    ...
    WithDescription = WithDescription,
    WithFailureDomain = WithFailureDomain,
```

`SelectComponents = SelectComponents` belongs in the `# components and their configs` group next to
`GetConfigs` (it is the second consumer of the same traversal); `WithLabels = WithLabels` beside
`WithDescription`/`WithFailureDomain`.

No new load edge — `platform.pinc` already loads `core.pinc`, and `core.pinc` loads nothing back.
Acyclic constraint satisfied by construction.

---

### `drivers/cicd/github_actions/src/github_actions.pinc` — FOUND-04 / FOUND-05

**Analog 1 — the compile-time `fail()` in `TerraformPipeline`** (lines 596-604). This is the tone,
the message shape and the `for key in sorted(configs.keys())` loop the new checks copy:

```python
    # _slug is lossy — `a-b` and `a_b` collapse to the same job id — and jobs live in a
    # map, so a collision would not fail the workflow, it would quietly drop one config
    # out of the pipeline. That is the one failure this driver must never have.
    owner = {}
    for key in sorted(configs.keys()):
        id = _plan_id(key)
        if id in owner:
            fail("%s and %s produce the same job id %s" % (owner[id], key, id))
        owner[id] = key
```

Note the shape: a `#` block naming the *silent* failure being prevented, then a sorted iteration,
then a single-line `fail()` interpolating the offending keys. Both new checks follow it.

**Analog 2 — the producer map to extract** (`dependencies`, lines 112-129). The `_producers()`
extraction (RESEARCH.md Pattern 3) lifts exactly this block; note it already contains a `fail()`
that moves with it:

```python
def dependencies(configs):
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
```

`dependencies` is exported in the `actions` struct — extract the map into `_producers(configs)` and
leave `dependencies(configs)`' signature untouched.

**Analog 3 — the id machinery both checks reuse** (`_backend_state_id` 50-71, `_remote_state_id`
73-98, `_reads` 100-107). Do not write new backend inspection. `_backend_state_id` already handles
all five backends; note it returns `"local://%s"` for a local backend (so it is *not* `None` for
redis — FOUND-04 must test `backend.local` truthiness, not `_backend_state_id(...) == None`).
`_reads` can yield `None`; the `if state and state in producer` guard handles both cases in one
branch, matching line 116's existing `if state and state in producer and producer[state] != key`.

**Bodies:** RESEARCH.md §Code Examples 5 and 6 contain both checks verbatim, with pasted firing
output from a real compile. Use them as written, including `_dir(key)` for the label (a slice of
`key` is wrong when the domain is empty).

**Call site:** immediately before `deps = dependencies(configs)` at line 593, so a missing backend
is reported before an ordering derivation a missing backend would corrupt. Check bodies as
module-private `_`-prefixed functions above `TerraformPipeline`, matching `_check_acyclic`.

**Comment that must change (Pitfall 6):** lines 89-92, above `dependencies`, currently argue for
the tolerance D-17 removes:

```python
# dependencies maps each config key to the keys of the configs whose state it reads. A
# state read from outside this set — a hand-written module, another repository — yields no
# edge: there is no job here to wait for, and pretending otherwise would be a lie about
# what the pipeline actually orders.
```

Leaving it in place ships a driver whose prose contradicts its own code. Rewrite as part of the
FOUND-05 task.

---

### `test/src/core_test.mpconf:50` — redis `BACKEND` (D-15)

**Analog:** `ApiTaskComponent` in the same file, lines 78-81 — the correct form, 28 lines below:

```python
        WithState(
            lambda component: Workload("api-task", "ghcr.io/example/api:latest", 8080),
            BACKEND,
        ),
```

**Current (broken) line 50:**

```python
        WithState(lambda component: Workload("redis", "redis:7-alpine", 6379)),
```

**Fix:** one positional argument. `BACKEND` is already defined at lines 9-13 of the same file.
`protoconf fmt -w` decides whether it stays one line or wraps like the api-task form.

**Expected golden diff (RESEARCH.md §Code Examples 7) — exactly two files:**
`test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON` and
`test/outputs/core_test/us-east-1/redis/infra/main.tf.json`, both `local` → `s3`.
`.github/workflows/terraform.yaml` **does not change** — this corrects D-16. A workflow diff here
is a regression.

---

## Shared Patterns

### Compile-time `fail()` naming the fix
**Source:** `drivers/cicd/github_actions/src/github_actions.pinc:603` and `:105-108`
**Apply to:** both new checks in `github_actions.pinc`
Message interpolates the offending identifier and names the argument to change. Preceded by a `#`
block stating what fails silently without the check. Never a fallback, never a wrong answer.

### `WithX(...)` hook factory
**Source:** `src/platform/core.pinc:101-107` (`WithDescription`)
**Apply to:** `WithLabels`
Outer factory takes the declaration, inner `do(component, next)` mutates and calls `next`, return
`component_filter(do)`. `Inherit(...)` wraps the return only for inherited hooks (`WithFailureDomain`).

### Naming
**Source:** `.planning/codebase/CONVENTIONS.md`, confirmed in every file read
`PascalCase` for exported factories/constructors, `snake_case` for plumbing, `_leading_underscore`
for module-private driver helpers (`_producers`, `_check_remote_backends`, `_check_reads_are_produced`,
matching `_check_acyclic`, `_plan_id`, `_dir`), `UPPER_SNAKE` for constants (`MAIN_CONFIG`,
`TERRAFORM_VERSION`, `BACKEND`).

### Facade export
**Source:** `src/platform/platform.pinc:1-21` and `:42-72`
**Apply to:** any new exported symbol in `core.pinc`
Two edits per symbol: alphabetical in the `load(...)` list, grouped-by-comment in the `struct`.

### Golden-file verification
**Source:** `.planning/codebase/TESTING.md`; the loop is `cd test && make test` then `git diff`
**Apply to:** every task in this phase
Empty diff = behavior preserved. The redis `BACKEND` fix is the single sanctioned non-empty diff.

### Comment style
**Source:** every `.pinc` read. Comments state the *reason* and the failure mode avoided, in prose,
above the `def`. New code that copies the mechanism without the comment does not match the file.

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `.github/workflows/drift.yaml` | CI config | request-response | The only file at this path, `.github/workflows/terraform.yaml`, is **generated** by `github_actions.pinc` and copied in by `make workflows`. It is a *structural* reference for YAML shape only — never a file to copy from, extend, or hand-edit. Its 25 KB of OIDC credentials, matrix jobs and `terraform` setup are all wrong for a workflow that compiles and diffs and needs no secret. |

**Use instead:** RESEARCH.md §Code Examples 1, which is a complete verified workflow. The minimum
it needs, and nothing more:

- `on: pull_request` / `push: branches: [main]` / `workflow_dispatch`, `paths:` = source trees (D-03).
  Never `pull_request_target` — it runs contributor Starlark through a compiler.
- `permissions: contents: read` and nothing else. Do **not** copy the generated pipeline's
  `id-token: write`.
- `actions/checkout@v4` — the one thing worth matching with the generated pipeline
  (`github_actions.pinc:387`).
- Install pinned `protoconf v0.2.0-rc2` by sha256-verified tarball (D-04).
- `rm -f test/protoconf.lock` before the build — mandatory, Pitfall 1. Without it the build exits 1
  on every runner.
- `cd test && make test`.
- `git add -A -- <3 paths>` then `git diff --cached --exit-code -- <same 3 paths>` — the `add` is
  mandatory, Pitfall 3. `test/protoconf.lock` deliberately excluded, Pitfall 2.
- Failure message says `cd test && make test` and commit.
- No `terraform` install. No secrets.

## Metadata

**Analog search scope:** `src/platform/`, `drivers/cicd/github_actions/src/`,
`drivers/state/terraform/src/`, `test/src/`, `.github/workflows/`
**Files scanned:** 5 read in full or in targeted ranges; 1 directory listed
**Pattern extraction date:** 2026-09-07
