---
phase: 01-trustworthy-foundations
plan: 03
subsystem: infra
tags: [protoconf, starlark, terraform, terraform-backend, github-actions, compile-time-validation, cross-state]

# Dependency graph
requires:
  - phase: 01-trustworthy-foundations
    provides: "drift CI check asserting committed generated output matches a fresh compile (01-01) — the mechanism that proves exactly two golden files changed here"
  - phase: 01-trustworthy-foundations
    provides: "the assertion-probe pattern — an `.mpconf` returning `{}` that compiles under `make test` and materializes nothing (01-02)"
provides:
  - "`_check_remote_backends(configs)` — FOUND-04 compile gate: a config CI will apply that has no backend, a `local` backend, or a backend this driver cannot name is a compile error naming the component and `BACKEND` as `WithState`'s second argument"
  - "`_check_reads_are_produced(configs)` — FOUND-05 compile gate: a `terraform_remote_state` read matching no config's backend state id is a compile error naming both fixes"
  - "`_producers(configs)` — one definition of \"the states this pipeline writes\", shared by `dependencies` and the FOUND-05 gate"
  - "`test/src/handshake_test.mpconf` — the repo's only executable assertion that the apply-ordering derivation derives an edge, plus the two named switch points both gates are proven against"
  - "redis holds its Terraform state in S3 instead of on the runner's discarded disk"
affects: [03-database-fan-out, 04-service-mesh, 05-security-policy]

# Actuals (#2632)
actuals:
  tokens: 4200
  tasks: 3
  commits: 3

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Compile gates live where the assertion can be true: both checks are about the relationship between a config and the pipeline that will apply it, so they sit in `TerraformPipeline` rather than in a `.proto-validator` bound to `Component` (D-14)"
    - "Negative tests as scripted source mutations: a committed probe carries named switch points, an external script substitutes one and greps the compiler log for that gate's own message — the exit code proves nothing, because the mutation trips something either way"
    - "One producer map, two consumers — the ordering derivation and the gate that guards it read the same function rather than two loops that can drift apart"

key-files:
  created:
    - test/src/handshake_test.mpconf
  modified:
    - drivers/cicd/github_actions/src/github_actions.pinc
    - test/src/core_test.mpconf
    - test/outputs/core_test/us-east-1/redis/infra/main.tf.json
    - test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON
    - .planning/STATE.md
    - .planning/REQUIREMENTS.md

key-decisions:
  - "Both compile gates live in the CI driver's `TerraformPipeline` (D-14), not as a `.proto-validator` — a validator bound to `Component` runs before the component is flattened into a pipeline and cannot see the producer set"
  - "`MISMATCHED` and `LOCAL` are declared ABOVE the switch points they substitute into — Starlark evaluates a module top to bottom, so a forward reference dies with `undefined:` before reaching the gate, which is indistinguishable from a gate that stopped firing"
  - "`_check_remote_backends` tests `backend.local` structurally rather than via a `None` return from `_backend_state_id` — that helper returns a non-empty `local://` id for a local backend and would never fire on it"
  - "CONTEXT D-16 predicted a generated-workflow job-ordering diff from the redis fix; it does not occur — no config in the reference stack declares a `terraform_remote_state`, so a real redis state id gains no edge and a workflow diff there is a regression"

patterns-established:
  - "Switch-point probes: a committed fixture declares unused constants whose only purpose is to be substituted in by an external negative check, each carrying a comment naming the check it feeds so a reader does not delete it as dead code"
  - "Gate ordering is load-bearing and documented at the call site: `_check_remote_backends` before `_check_reads_are_produced` before `dependencies`, because a missing backend corrupts the producer map the two later steps read from"
  - "A gate's proof is its own message in the compiler log, never the exit code — mutations that reach a gate also break other assertions, so a non-zero exit is guaranteed either way"

requirements-completed: [FOUND-04, FOUND-05]

# Coverage metadata (#1602)
coverage:
  - id: D1
    description: "Redis's Terraform state is held in S3 rather than on the CI runner's disk, so an apply no longer plans against nothing and recreates the deployment every run"
    requirement: FOUND-04
    verification:
      - kind: other
        ref: "cd test && /usr/bin/make test; git diff --name-only over the three drift-asserted trees lists exactly the two redis infra goldens"
        status: pass
      - kind: other
        ref: "grep for \"bucket\": \"platform-engineering-tfstate\" / \"key\": \"us-east-1/redis.tfstate\" / \"region\": \"us-east-1\" in test/outputs/core_test/us-east-1/redis/infra/main.tf.json"
        status: pass
    human_judgment: false
  - id: D2
    description: "A component whose state CI will apply, but that renders a local backend, fails at compile time with a message naming that component and naming BACKEND as WithState's second argument"
    requirement: FOUND-04
    verification:
      - kind: integration
        ref: "scripted negative check: sed NEAR_BACKEND=LOCAL into test/src/handshake_test.mpconf, `protoconf compile .` exits 1 with `TerraformPipeline: handshake/pub/infra writes local Terraform state ... Pass BACKEND as the second argument to WithState(...)`; probe restored, mutation confirmed written before the compile"
        status: pass
    human_judgment: false
  - id: D3
    description: "A cross-state terraform_remote_state read whose state id matches no other config's backend state id fails at compile time with a message naming both fixes"
    requirement: FOUND-05
    verification:
      - kind: integration
        ref: "scripted negative check: sed FAR_BACKEND=MISMATCHED into test/src/handshake_test.mpconf, `protoconf compile .` exits 1 with `... reads the Terraform state s3://handshake-test-nobody-writes-this/... which no config in this pipeline writes ... or pass the same backend to both halves of the handshake.`; probe restored"
        status: pass
    human_judgment: false
  - id: D4
    description: "A correctly-paired cross-state handshake compiles silently AND produces the ordering edge the pipeline applies in — the reader's plan job waits on the writer's"
    requirement: FOUND-05
    verification:
      - kind: integration
        ref: "test/src/handshake_test.mpconf#actions.dependencies assertion (compiled by `cd test && /usr/bin/make test`): sub -> [pub], pub -> []"
        status: pass
      - kind: integration
        ref: "RED evidence recorded before the gates existed: FAR_BACKEND=MISMATCHED tripped this probe's own fail() with `got {pub: [], sub: []}`, proving the assertion is live and the edge real rather than vacuous"
        status: pass
    human_judgment: false
  - id: D5
    description: "Adding two compile-time guards changes no generated output, and the generated workflow stays byte-identical after the redis backend fix"
    verification:
      - kind: other
        ref: "cd test && /usr/bin/make test && git add -AN -- <3 drift-asserted trees> && git diff --exit-code -- <same> (run after Task 2 and after Task 3)"
        status: pass
      - kind: other
        ref: "git diff --quiet -- .github/workflows/terraform.yaml test/outputs/core_test/.github/workflows/terraform.yaml test/materialized_config/core_test/.github/workflows/terraform.yaml.materialized_JSON"
        status: pass
    human_judgment: false
  - id: D6
    description: "The comment above `dependencies` describes the behaviour the driver now has, rather than arguing for the tolerance D-17 traded away"
    verification:
      - kind: other
        ref: "grep -c 'pretending otherwise' drivers/cicd/github_actions/src/github_actions.pinc == 0"
        status: pass
    human_judgment: true
    rationale: "A grep proves the superseded text is gone; only a reader can tell whether the replacement is honest about the trade. This is the plan's own `<human-check>` and is deferred to end-of-phase verification per `human_verify_mode: end-of-phase`."

# Metrics
duration: 6 min
completed: 2026-09-07
status: complete
---

# Phase 01 Plan 03: Compile-Time Enforcement of Terraform State Wiring Summary

**Two classes of silently-wrong Terraform wiring — a CI-applied state with a disposable local backend, and a cross-state read the apply-ordering derivation cannot see — are now compile errors naming the component and the argument to change, with both gates proven to fire by scripted source mutations rather than by assertion.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-09-07T17:49:43Z
- **Completed:** 2026-09-07T17:55:16Z
- **Tasks:** 3
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments

- **Fixed the live instance before shipping the guard.** `test/src/core_test.mpconf:50` built `RedisComponent`'s state with a single positional argument to `WithState`, so `backend = backend or DEFAULT_BACKEND` selected `LocalBackend()`. CI was applying redis against a runner disk that is discarded at the end of every job — every apply planned against an empty state and recreated the Deployment and Service. One argument (`BACKEND`) fixes it, and the guard that would have caught it landed two commits later.
- **FOUND-04 (`_check_remote_backends`)** — three `fail()` branches over `sorted(configs.keys())`, covering all three of D-15's trigger conditions: no backend at all, a backend whose `local` arm is set, and a backend that is set but that `_backend_state_id` cannot name. The third is unreachable through today's five constructors in `terraform.pinc`; it exists so a sixth cannot pass the gate and then be silently skipped by `_producers`, leaving a config with an apply job and no orderable state.
- **FOUND-05 (`_check_reads_are_produced`)** — a `terraform_remote_state` read matching no config's backend state id is fatal. One guard (`if state and state in producer`) catches both a `None` from `_remote_state_id` and a named state nobody here writes; the message names both fixes.
- **`_producers(configs)` extracted** from `dependencies`, duplicate-state `fail()` moving with it unchanged. "The states this pipeline writes" now has one definition and two consumers instead of two loops that can drift apart — and the drift would have been invisible, with the gate passing on a state the derivation then ignored.
- **`test/src/handshake_test.mpconf`** — the repo's only config that asks the ordering derivation a question it could get wrong. No config in the reference stack declares a `terraform_remote_state` at all, so `dependencies()` had never returned a non-empty upstream list in a committed build.

## Task Commits

1. **Task 1: Redis stops losing its Terraform state on every apply** — `ed71f09` (fix)
2. **Task 2: A correct cross-state handshake is proven to derive its apply-ordering edge** — `394b7ac` (test)
3. **Task 3: Two silently-wrong Terraform wirings become compile errors** — `80cc106` (feat)

**Plan metadata:** see the `docs(01-03)` commit that carries this file.

## Files Created/Modified

- `test/src/handshake_test.mpconf` (new) — pub/sub pair wired through a correctly paired `WithRemoteOutput` handshake. Asserts `actions.dependencies(configs)` maps `handshake/sub/infra/main.tf.json -> [handshake/pub/infra/main.tf.json]` and the publisher to `[]`. `main()` returns `{}`, so it writes no golden file. Carries `NEAR_BACKEND` / `FAR_BACKEND` as switch points and `MISMATCHED` / `LOCAL` as the values substituted in.
- `drivers/cicd/github_actions/src/github_actions.pinc` — `_producers`, `_check_remote_backends`, `_check_reads_are_produced`; both gates called from `TerraformPipeline` before `deps = dependencies(configs)`; the comment above `dependencies` rewritten.
- `test/src/core_test.mpconf` — `BACKEND` passed as `WithState`'s second positional argument inside `RedisComponent`.
- `test/outputs/core_test/us-east-1/redis/infra/main.tf.json` and its `test/materialized_config/` twin — backend block `local` → `s3` (bucket `platform-engineering-tfstate`, key `us-east-1/redis.tfstate`, region `us-east-1`). The only two golden files that changed.

## Decisions Made

- **Gates in `TerraformPipeline`, not a validator (D-14).** `CONVENTIONS.md` prefers a `.proto-validator` over a driver `fail()`, and that guidance is right for anything expressible about a `Component` in isolation. Neither of these is: both are assertions about the relationship between a config and the pipeline that will apply it, and a validator bound to `Component` runs before the component is ever flattened into a pipeline. No `.proto-validator` file was created, and `drivers/state/terraform/src/terraform.pinc` was not touched.
- **`backend.local` tested structurally.** An empty `BackendLocal` message is truthy when the field is set — exactly what the redis config rendered before Task 1 — while `_backend_state_id` returns a perfectly usable `local://` id for it. A check written against a `None` return would never have fired on the one bug this repo actually had.
- **Gate ordering is load-bearing.** `_check_remote_backends` → `_check_reads_are_produced` → `dependencies`. A config with no usable backend corrupts the producer map the latter two read from, so reporting the missing backend first hands the contributor the cause rather than a confusing consequence.
- **The probe's `TerraformPipeline` call comes before its `dependencies` assertion.** Both switch-point substitutions also break the assertion, and Starlark cannot catch a `fail()` in-process, so assertion-first would have made both gates unreachable — with a non-zero exit either way, the miss would have been invisible.
- **No escape hatch for genuinely external state (T-01-12, accepted).** Nothing in the reference stack reads a state applied elsewhere. Building the hatch speculatively would reintroduce the tolerance the check removes; when a real case appears it is a one-argument addition to `TerraformPipeline`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `MISMATCHED` and `LOCAL` were declared below the switch points they substitute into, making both negative checks unable to reach their gates**

- **Found during:** Task 2 (writing `handshake_test.mpconf`, before committing it)
- **Issue:** The plan's action lists the four module constants in the order base `BACKEND`, `NEAR_BACKEND`, `FAR_BACKEND`, then `MISMATCHED`/`LOCAL`, and the first draft followed it. Starlark evaluates a module top to bottom, so `FAR_BACKEND = MISMATCHED` at line 48 referred forward to a name defined at line 57 and the compile died with `handshake_test.mpconf:48:15: undefined: MISMATCHED` during module load — before `main()` ran, before `TerraformPipeline` was entered, before any gate existed to fire. This is precisely the failure mode the plan warns about in a different guise: a non-zero exit with the gate's message absent from the log, which is indistinguishable from a gate that has quietly stopped firing. Task 3's two `<verify>` gates would have reported `FAIL` on working gates.
- **Fix:** Moved `MISMATCHED` and `LOCAL` above `NEAR_BACKEND`/`FAR_BACKEND`, with a comment at the declaration site stating why the order is not cosmetic.
- **Files modified:** `test/src/handshake_test.mpconf`
- **Verification:** Re-ran both substitutions before committing Task 2. With the gates not yet written, `NEAR_BACKEND = LOCAL` reached the duplicate-state `fail()` inside `_producers` (`both write the Terraform state local://`) and `FAR_BACKEND = MISMATCHED` reached the probe's own assertion (`got {pub: [], sub: []}`) — exactly the two pre-gate outcomes the plan predicted, confirming both mutations now reach live code instead of dying at module load.
- **Committed in:** `394b7ac` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** The fix is a reordering of four constants in a new file, invisible to every other artifact. It converted two negative checks that would have produced false `FAIL`s into two that actually exercise the gates. No scope change.

## Issues Encountered

- **The environment traps named in the dispatch are real, and both bit.** `make` on PATH is a broken zsh autoload stub — `/usr/bin/make` was used throughout. zsh's `noclobber` silently refused the `>` redirects in the decision-recording loop after the first write, so three of four `state.add-decision` calls wrote nothing; re-running the loop under `bash -c` fixed it. Every source-mutating negative check in this plan was run under `bash -c` for that reason, and each was instrumented to confirm the mutation had actually landed (via `git diff --stat` / `diff -q`) before any conclusion was drawn from the compile result.
- **`state.add-decision --summary-file` rejects paths outside the repository**, including the session scratchpad under `/tmp`. Worked around with a short-lived `.planning/.tmp/` file, removed after.

## TDD Gate Compliance

Task 2 carries `tdd="true"`, and the standard RED gate does not apply to it in the usual form: the behaviour being asserted — the apply-ordering derivation in `dependencies()` — already shipped and is listed under PROJECT.md's Validated requirements. The probe is a characterization test of existing behaviour, and the plan's own `<verify>` requires `make test` to exit 0, i.e. the assertion to pass on first run. Proceeding on an unexpectedly-passing test would normally be a fail-fast violation, so RED evidence was obtained explicitly instead, before the Task 2 commit: substituting `FAR_BACKEND = MISMATCHED` made the probe fail with its own message and the actual map `{pub: [], sub: []}`, proving the assertion is live and specific rather than vacuously true. Commit sequence is `test(01-03)` (`394b7ac`) → `feat(01-03)` (`80cc106`); no `refactor` commit, as none was needed.

## Verification Results

| Plan verification step | Result |
|---|---|
| 1. `cd test && make test` exits 0, golden trees clean at end of plan | PASS |
| 2. Exactly two golden files changed across the plan, both redis infra; all three workflow artifacts byte-identical | PASS — `git diff --name-status` over the plan's three commits lists 5 files, exactly 2 of them goldens |
| 3. Both negative checks: `protoconf compile .` fails with the expected named message, probe restored | PASS — `writes local Terraform state` + `WithState`; `no config in` + `both halves of the handshake` |
| 4. All acceptance criteria in all three tasks | PASS |
| 5. The `drift` workflow stays green | Deferred — its local equivalent (`make test` + `git diff --exit-code` over the three trees) passes; the first CI run confirms Assumption A1 (linux_amd64 byte-reproducibility, measured only on darwin/arm64) |

## User Setup Required

None — no external service configuration required.

## Operational Note (carried forward from the plan, T-01-13)

**The redis S3 state starts empty.** Giving redis a real backend does not migrate state that already existed — and before this change no state persisted at all, which is the bug. The first apply against `s3://platform-engineering-tfstate/us-east-1/redis.tfstate` starts from an empty state and will plan to CREATE the Kubernetes Deployment and Service. If a live cluster already holds them, that apply needs a `terraform import` or a targeted reconciliation before it runs unattended. This transfers to whoever merges and applies; no task in this plan addresses it.

## Next Phase Readiness

- **Phase 1 is complete.** All five requirements (FOUND-01..05) are marked Complete in REQUIREMENTS.md.
- **Phase 3 (DATA-05) inherits a guarantee, not a hope.** The near/far handshake convention the database driver will author is now enforceable: a driver that pairs the two halves against different backends fails compile with a message naming the fix, and `handshake_test.mpconf` demonstrates on every build that a correct pairing produces the ordering edge.
- **Open:** Assumption A1 — golden-file byte-reproducibility was measured on darwin/arm64, not on the linux_amd64 runner the drift workflow uses. The first CI run of `drift` is the confirmation.
- **Open (review-only):** the plan's `<human-check>` on the rewritten comment above `def dependencies`. A grep proves the superseded text is gone; a reader is needed to confirm the replacement is honest about the trade. Deferred to end-of-phase verification.

## Self-Check: PASSED

All five key files verified present on disk. All three task commits (`ed71f09`, `394b7ac`, `80cc106`) verified in `git log`. Working tree clean on `test/`, `drivers/` and `src/`.

---
*Phase: 01-trustworthy-foundations*
*Completed: 2026-09-07*
