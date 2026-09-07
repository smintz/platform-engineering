---
phase: 01-trustworthy-foundations
plan: 01
subsystem: infra
tags: [github-actions, ci, protoconf, golden-files, drift-detection, supply-chain]

# Dependency graph
requires: []
provides:
  - "`.github/workflows/drift.yaml` — hand-written CI check that recompiles the source with a pinned protoconf and fails when the committed generated output no longer matches"
  - "A single generated-output tree in the repository (`test/outputs/`, `test/materialized_config/`) — the orphan root trees are gone"
  - "A mechanical answer to \"did I break the build?\" that plans 01-02 and 01-03 are verified against"
affects: [01-02, 01-03, all future phases touching src/, drivers/ or test/src/]

# Actuals (#2632)
actuals:
  tokens: 1700
  tasks: 2
  commits: 2

# Tech tracking
tech-stack:
  added: [protoconf v0.2.0-rc2 release binary (CI only, sha256-pinned)]
  patterns:
    - "Hand-written CI for the checker of a generated artifact (D-01) — the one exception to \"CI is generated\" in this repo"
    - "Stage-then-diff (`git add -A --` then `git diff --cached --exit-code --`) as the golden-file assertion, so new output files fail instead of passing green"

key-files:
  created: [.github/workflows/drift.yaml]
  modified: []

key-decisions:
  - "Added `.github/workflows/terraform.yaml` to both `paths:` trigger filters, beyond the five source paths D-03 names — it is one of the three asserted trees and is never hand-edited, so a PR that only tampers with it would otherwise match no trigger and ship green"
  - "Deleted the four orphan root files by explicit path rather than `git rm -r` on the directories — same result (git prunes the emptied directories), narrower blast radius"
  - "Left `test/protoconf.lock` in the trigger filter but out of the assertion — CI regenerates it every run, and even locally the release binary and the dev build disagree about its JSON whitespace"

patterns-established:
  - "Drift assertion covers exactly three trees: test/materialized_config/, test/outputs/, .github/workflows/terraform.yaml — the workflow copy is a separate `make workflows` write and can go stale independently"
  - "CI deletes the machine-local protoconf.lock before building rather than rewriting the committed one — the lock's absolute file:// paths are a deferred fix, not a CI blocker"

requirements-completed: [FOUND-01]

# Coverage metadata (#1602)
coverage:
  - id: D1
    description: "A push or PR editing test/src/**, src/**, drivers/** or test/CONFIGSPACE without a regenerated build fails the drift workflow"
    requirement: FOUND-01
    verification:
      - kind: integration
        ref: "scratch git repo replaying the workflow's verbatim assertion step: clean -> exit 0, modified tracked golden -> exit 1"
        status: pass
      - kind: other
        ref: "cd test && make test && git add -AN -- <3 trees> && git diff --exit-code -- <3 trees>"
        status: pass
    human_judgment: false
  - id: D2
    description: "A change that ADDS a new output file — a new component's new state directory — also fails the drift check, because the assertion stages before it diffs"
    requirement: FOUND-01
    verification:
      - kind: integration
        ref: "scratch git repo replaying the workflow's verbatim assertion step with an untracked test/outputs/newcomponent/main.tf.json present -> exit 1"
        status: pass
    human_judgment: false
  - id: D3
    description: "The drift workflow holds no privilege it does not need: contents:read only, no OIDC, no secrets, no terraform install, no fork-context trigger, and its compiler is pinned by version and sha256"
    requirement: FOUND-01
    verification:
      - kind: other
        ref: "Task 1 gate 3 — comment-filtered negative grep for the fork-context trigger, id-token, setup-terraform, terraform_remote_state and secrets. — all zero"
        status: pass
      - kind: other
        ref: "python3 yaml.safe_load assertion: permissions == {contents: read}, on == {pull_request, push, workflow_dispatch}, jobs == [compile]"
        status: pass
    human_judgment: false
  - id: D4
    description: "Exactly one generated-output tree exists in the repository, under test/ — the orphan root outputs/ and materialized_config/ trees are gone, and the test/ build is undisturbed by their removal"
    requirement: FOUND-01
    verification:
      - kind: other
        ref: "git ls-files -- outputs materialized_config == empty; neither directory exists; Makefile and providers.tf unmodified; cd test && make test exits 0 with an empty diff on the three asserted trees"
        status: pass
    human_judgment: false
  - id: D5
    description: "First real drift run on a linux_amd64 GitHub runner is green (Assumption A1 — byte-reproducibility of the goldens was measured on darwin/arm64)"
    requirement: FOUND-01
    verification: []
    human_judgment: true
    rationale: "Cannot be executed locally. Requires the workflow to actually run on GitHub Actions; the plan's own <human-check> reserves this. A red run showing a uniform diff on files nobody edited is A1 breaking — a finding about the compiler, not about this plan."

# Metrics
duration: 7min
completed: 2026-09-07
status: complete
---

# Phase 01 Plan 01: Drift Check Foundation Summary

**A hand-written `drift` workflow that recompiles the source with a sha256-pinned protoconf v0.2.0-rc2 and fails the build when `test/outputs/`, `test/materialized_config/` or the generated `.github/workflows/terraform.yaml` is stale — plus the deletion of the orphan root output trees that made "is the output current?" unanswerable for half the repository.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-09-07T17:28:45Z
- **Completed:** 2026-09-07T17:35:27Z
- **Tasks:** 2
- **Files modified:** 5 (1 created, 4 deleted)

## Accomplishments

- **CI now runs `protoconf compile`.** `.planning/codebase/TESTING.md` named its absence "the largest gap in the current setup": the existing pipeline plans and applies the *committed* `test/outputs/`, so a source edit without `make -C test` merged green against stale generated Terraform. It no longer can.
- **The guard can fire on its own failure mode.** The generated pipeline filters on `test/outputs/core_test/**`, which by construction cannot trigger for a source edit with no regenerated output. `drift` triggers on the source trees instead (D-03).
- **A brand-new output file fails the check too.** The assertion stages (`git add -A --`) before it diffs, so a new component's untracked state directory is visible to `git diff` — the silent-by-construction failure of RESEARCH §Pitfall 3, designed out rather than watched for.
- **The check has exactly one output tree in scope.** Four orphan root files describing an `aurora-user-api-task` component that exists in no `.mpconf` are gone (D-05).
- **The tracer closed end to end.** This plan touched every layer the phase modifies — source trigger, compiler pin, the real build (`test/Makefile`), the golden trees, and the workflow copy at the repo root — with a real assertion at the end. Plans 01-02 and 01-03 now have a mechanical verdict on "did I break the build?".

## Task Commits

Each task was committed atomically:

1. **Task 1 (tracer): drift.yaml compiles the source and asserts the committed output matches** — `993b988` (feat)
2. **Task 2: delete the orphan root output trees** — `722e7ce` (chore)

**Plan metadata:** see the `docs(01-01)` commit following this file.

## Files Created/Modified

- `.github/workflows/drift.yaml` (created, 76 lines) — the drift check. Triggers on `pull_request` / `push` to `main` / `workflow_dispatch`, filtered to `test/src/**`, `src/**`, `drivers/**`, `test/CONFIGSPACE`, `test/protoconf.lock` and `.github/workflows/terraform.yaml`. One job: checkout, install sha256-verified protoconf, `rm -f test/protoconf.lock`, `cd test && make test`, stage-and-diff the three generated trees.
- `outputs/platform/core_test/us-east-1/aurora-user-api-task/aurora_endpoint.tf.json` (deleted)
- `outputs/platform/core_test/us-east-1/aurora-user-api-task/infra/main.tf.json` (deleted)
- `materialized_config/platform/core_test/us-east-1/aurora-user-api-task/aurora_endpoint.tf.json.materialized_JSON` (deleted)
- `materialized_config/platform/core_test/us-east-1/aurora-user-api-task/infra/main.tf.json.materialized_JSON` (deleted)

Nothing under `src/`, `drivers/` or `test/src/` changed — verified with `git diff --name-only 031b32c..HEAD -- src drivers test/src` (empty). This plan adds a guard; it does not change what is guarded.

## Decisions Made

- **`.github/workflows/terraform.yaml` added to both `paths:` filters.** D-03 fixes the *source* trigger list; the generated workflow copy is not a source tree, but it is one of the three trees the assertion covers and this plan's own prohibitions say it is never hand-edited. Without it in the filter, a PR whose only change is a hand-edit of the generated workflow matches no trigger, drift never runs, and the tamper lands green — the guard would be blind to exactly the artifact it exists to protect. This is within the latitude CONTEXT grants over "exact workflow YAML structure" and contradicts nothing D-03 says. It was already written into the plan's `must_haves` and acceptance criteria; recorded here because it is the one place this file departs from RESEARCH §Code Examples 1 verbatim.
- **Deleted the four orphan files by explicit path, not `git rm -r outputs materialized_config`.** Identical outcome — those four were the only tracked or on-disk files in either tree, and git prunes the emptied directories — with a narrower command. (The recursive form was also refused by the sandbox classifier; the per-path form is what the plan enumerates anyway.)
- **`test/protoconf.lock` is in the trigger but not the assertion.** A lock change is a real reason to recompile, so it triggers. It is not a thing the check can assert on: CI deletes and regenerates it, and even locally the rc2 release binary writes one space after each JSON colon where the committed lock (dev build) writes two.

## Deviations from Plan

None — plan executed exactly as written. No deviation rule fired: no bug, no missing critical functionality, no blocker, no architectural question.

The one thing worth flagging is not a deviation but an environment note: the shell's `make` is a broken zsh autoload stub (`make: function definition file not found`), so every local build in this plan invoked `/usr/bin/make` directly. This affects local reproduction only — the workflow runs on ubuntu-latest where `make` is a real binary on PATH. Nothing in the repo was changed for it.

## Issues Encountered

None.

## Verification Results

Plan-level `<verification>`, re-run after the final commit:

1. **`cd test && make test` exits 0 and the three drift-asserted trees diff empty** — PASS. Run twice (after Task 1, and again after Task 2's deletions). `MAKE_EXIT=0`, `git diff --exit-code -- test/materialized_config test/outputs .github/workflows/terraform.yaml` → 0. `test/protoconf.lock` was not rewritten locally either.
2. **`.github/workflows/drift.yaml` passes all three Task 1 `<automated>` gates** — PASS, PASS, PASS. Gate 2 (seven required strings present) and gate 3 (comment-filtered negative grep: no fork-context trigger, no `id-token`, no `setup-terraform`/`terraform_remote_state`/`secrets.`) both returned 0.
3. **`git ls-files -- outputs materialized_config` is empty; root `Makefile` and `providers.tf` unmodified** — PASS. Neither directory exists on disk; both files are still tracked and show no diff against HEAD (D-06 honoured).
4. **First-run verification (Assumption A1)** — DEFERRED to the human check below. Not executable locally.

Additional checks run beyond the plan's gates:

- **YAML structural parse** (`yaml.safe_load`): `on:` declares exactly `pull_request`, `push`, `workflow_dispatch`; both `paths:` lists are the six expected entries in order; `push.branches == [main]`; `permissions == {contents: read}` and nothing else; one job, `compile`; the `rm -f test/protoconf.lock` step precedes the `rebuild` step. All assertions passed.
- **`bash -n` on every `run:` block** — all four parse clean, including the `|| { ... }` continuation in the assertion step.
- **The assertion step, replayed verbatim in a scratch git repo** — extracted from the committed workflow by YAML parse, not retyped:
  - clean tree → exit 0
  - modified tracked golden → exit 1
  - **new untracked `test/outputs/newcomponent/main.tf.json` → exit 1**

  The third case is the one that matters: without the `git add -A --` it would have returned 0. This is the proof that the check catches a new component, not just an edited one.

## Human Verification Required

**Open the first `drift` workflow run on branch `feat/k8s-stack-monitoring-ci` in GitHub Actions and confirm it is green.**

Byte-reproducibility of the golden files was measured on darwin/arm64 (locally, and in RESEARCH's `git archive` transcript). The workflow runs the `linux_amd64` release binary. If the run is red, read the printed diff:

- A diff naming files the PR actually edited → a real drift catch, working as designed.
- A **uniform diff touching files nobody edited** → Assumption A1 breaking: the linux release binary does not reproduce the darwin-built goldens. That is a finding about the compiler, not about this plan, and it would need the goldens regenerated on linux (or the pin moved) before `drift` can be trusted.

## User Setup Required

None — no external service configuration required. The job authenticates to nothing: every `remote_repo` in `test/CONFIGSPACE` is a local relative path, so the build is hermetic and offline apart from the single pinned, checksum-verified protoconf download. No repository secret, variable, or OIDC role is needed.

## Threat Model Coverage

All `mitigate` dispositions from the plan's register are implemented and verified:

| Threat | Mitigation shipped | Verified by |
|--------|-------------------|-------------|
| T-01-01 (EoP, trigger block) | Only `pull_request`, `push: main`, `workflow_dispatch` — never the fork-context variant that runs contributor Starlark against a write-scoped token | Gate 3 negative grep + YAML parse |
| T-01-02 (EoP, permissions) | `permissions: {contents: read}` and nothing else; no OIDC grant, no `secrets.` reference | Gate 3 negative grep + YAML parse asserting the dict is exactly one key |
| T-01-03 (Tampering, binary download) | Pinned to `v0.2.0-rc2` **and** to sha256 `eeb8415960…`, verified with `sha256sum -c -` before extraction | Gate 2 string check |
| T-01-04 (Tampering, `actions/checkout@v4`) | Accepted, as planned — matches the pin the repo's own generated pipeline uses at `github_actions.pinc:387` | n/a (accepted) |
| T-01-05 (Info disclosure, `protoconf.lock`) | Accepted, as planned — CI deletes its local copy rather than rewriting the committed one; the leak stays in Deferred | n/a (accepted) |

No new security-relevant surface was introduced beyond the register. No threat flags.

## Next Phase Readiness

- **Ready for 01-02** (`walk_upstreams` / `SelectComponents` / `WithLabels`). Its D-12 verification — "an empty `git diff` on `test/materialized_config/` and `test/outputs/` after `cd test && make test`" — is now the workflow's own assertion, and the baseline it diffs against is confirmed clean at `722e7ce`.
- **Ready for 01-03.** Note for that plan: D-16's deliberate redis backend golden diff is the one place in Phase 1 where a non-empty diff is correct. `drift` will go red on it in CI until the regenerated goldens are committed in the same change — that is the check working, not a regression.
- **Open, tracked in the human check above:** whether the linux release binary reproduces the darwin-built goldens (Assumption A1). Until the first CI run, `drift`'s green-on-clean behaviour is proven locally only.

---
*Phase: 01-trustworthy-foundations*
*Completed: 2026-09-07*

## Self-Check: PASSED

- `.github/workflows/drift.yaml` — FOUND on disk, git-tracked
- `.planning/phases/01-trustworthy-foundations/01-01-SUMMARY.md` — FOUND on disk
- Commit `993b988` (feat) — FOUND in git log
- Commit `722e7ce` (chore) — FOUND in git log
- Commit `85d1b20` (docs) — FOUND in git log
- Root `outputs/` and `materialized_config/` — GONE, as claimed
