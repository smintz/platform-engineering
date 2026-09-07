---
phase: 01-trustworthy-foundations
plan: 02
subsystem: infra
tags: [protoconf, starlark, protobuf, component-graph, selector]

requires:
  - phase: 01-trustworthy-foundations
    provides: drift CI check asserting committed generated output matches a fresh compile
provides:
  - "`walk_upstreams(component, next)` — the component-graph traversal, lifted to module level in `src/platform/core.pinc` with two consumers instead of one"
  - "`SelectComponents(component, predicate)` — every component in a dependency graph the predicate accepts, post-order, de-duplicated by structural equality, empty list on no match"
  - "`WithLabels(**labels)` — ordinary `component_filter` hook writing `Component.Metadata.labels`"
  - "`platform.SelectComponents` / `platform.WithLabels` facade exports"
  - "`test/src/select_test.mpconf` — the repo's first executable assertion, running inside `make test` and materializing nothing"
affects: [02-cost-attribution, 05-security-policy]

actuals:
  tokens: 6800
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "Assertion probe: an `.mpconf` whose `main()` returns `{}` writes no output file, so a compile-time assertion costs zero golden-file surface and runs inside the existing build"
    - "De-duplication of proto messages by structural equality in a Starlark `dict` — messages hash and compare by value here"

key-files:
  created:
    - test/src/select_test.mpconf
  modified:
    - src/platform/core.pinc
    - src/platform/platform.pinc
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md

key-decisions:
  - "De-duplicate by structural equality on the message rather than by a `<domain>/<name>` string key — a string key silently asserts a uniqueness the schema does not enforce"
  - "`WithLabels` is a plain `component_filter`, not `Inherit(...)` — whether a label should reach a component's whole dependency subtree is a Phase 2 (COST-01) question"
  - "`SelectComponents` returns an empty list on no match rather than failing — a caller that needs a zero match to be an error (Phase 5 SEC-02) can say so itself"
  - "The negative check runs under `bash -c`, not the repo shell — zsh's `noclobber` refuses the `>` redirect the check depends on"

patterns-established:
  - "One traversal, many consumers: a graph walk lives at module level and takes a `next` callback, so a second consumer is a closure rather than a second walk"
  - "Executable assertions live in a committed `.mpconf` returning `{}`, compiled by `make test`, with `fail()` messages carrying a grep-able literal prefix so a tripped assertion is distinguishable from a file that merely did not compile"

requirements-completed: [FOUND-02, FOUND-03]

coverage:
  - id: D1
    description: "A platform author writes `platform.WithLabels(tier = \"cache\")` on a component and the pair lands in `Component.Metadata.labels`, including on a component whose `metadata` was never constructed"
    requirement: FOUND-02
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#tier=app and tier=cache selections (compiled by `cd test && make test`)"
        status: pass
      - kind: other
        ref: "grep -c 'Inherit(component_filter(do))' src/platform/core.pinc == 1 && grep -c 'metadata.tags' src/platform/core.pinc == 0"
        status: pass
    human_judgment: false
  - id: D2
    description: "`platform.SelectComponents(root_msg, predicate)` returns every matching component in the dependency graph once, in post-order, and an empty list when nothing matches"
    requirement: FOUND-03
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#always-true selection returns ['leaf','base','mid1','mid2','top'] (diamond de-dup + post-order in one comparison)"
        status: pass
      - kind: integration
        ref: "test/src/select_test.mpconf#empty-match selection returns []"
        status: pass
      - kind: other
        ref: "negative check — relabelling the leaf makes `protoconf compile .` exit 1 emitting 'SelectComponents: expected'"
        status: pass
    human_judgment: false
  - id: D3
    description: "Lifting the traversal out of `GetConfigs` is behaviour-preserving: the reference stack recompiles to byte-identical output (D-12)"
    verification:
      - kind: e2e
        ref: "cd test && make test; git add -AN -- test/materialized_config test/outputs .github/workflows/terraform.yaml; git diff --exit-code -- <same>"
        status: pass
      - kind: other
        ref: "def walk_upstreams appears exactly once in core.pinc and zero times inside the GetConfigs body"
        status: pass
    human_judgment: false
  - id: D4
    description: "Both symbols reach a call site through the `platform` facade with no new load edge, and the proto schema is untouched"
    verification:
      - kind: other
        ref: "grep for load-list + struct entries in platform.pinc; grep -c '\"//platform/platform.pinc\"' core.pinc == 0; git diff HEAD --name-only -- src/platform/v1/platform.proto empty"
        status: pass
    human_judgment: false
  - id: D5
    description: "No planning artifact still names the `Component.tags` field D-07 decided against"
    verification:
      - kind: other
        ref: "grep -c 'Component\\.tags' over .planning/REQUIREMENTS.md and .planning/ROADMAP.md both return 0; both name Component.Metadata.labels"
        status: pass
    human_judgment: false
  - id: D6
    description: "`GetConfigs`' doc comment still sits directly above its own `def` and each new symbol carries a rationale comment in the register of the surrounding file"
    verification: []
    human_judgment: true
    rationale: "Correctness-of-reading, explicitly called out as the plan's `<human-check>`. No grep can tell an orphaned doc comment from an intentional one, or judge whether a rationale comment says why rather than what."

duration: 7 min
completed: 2026-09-07
status: complete
---

# Phase 1 Plan 2: Component Shape and Selection Summary

**`SelectComponents(root, predicate)` over a module-level `walk_upstreams` shared with `GetConfigs`, `WithLabels(**labels)` writing `Component.Metadata.labels`, and the repo's first executable assertion — a zero-output `.mpconf` probe that proves diamond de-duplication on every build.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-09-07T17:39:00Z
- **Completed:** 2026-09-07T17:46:00Z
- **Tasks:** 2
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments

- **FOUND-02 closed.** `WithLabels(**labels)` gives a component declared key/value shape in the field the schema already had (`Component.Metadata.labels`), constructing `Metadata()` before writing so it works on a component that has none. Ordinary `component_filter`, not `Inherit` — D-09.
- **FOUND-03 closed.** `SelectComponents(component, predicate)` returns every component in the graph the predicate accepts, post-order, de-duplicated, empty list on no match. Exported through the `platform` facade.
- **D-10 honoured.** The traversal `GetConfigs` owned as a nested closure now lives at module level with two consumers. There is exactly one walk in the file, and zero inside `GetConfigs`.
- **D-12 proven.** The reference stack recompiles byte-identical: `cd test && make test` leaves `test/outputs/`, `test/materialized_config/` and the installed `.github/workflows/terraform.yaml` with an empty diff (staged first, per Pitfall 3 — `git diff` is blind to new files).
- **First executable test in the repo.** `test/src/select_test.mpconf` asserts de-duplication, ordering, label filtering and the empty-match case, and is demonstrably capable of failing — the negative check trips it with a named message rather than a compile error.
- **Downstream drift closed before it landed.** REQUIREMENTS.md FOUND-02 and both ROADMAP.md references now name `Component.Metadata.labels`, so Phase 5's SEC-01 is planned against the field the code actually has.

## Task Commits

1. **Task 1: Declare a component's shape and select on it** — `e095f56` (feat)
2. **Task 2: Assert the de-duplication, ordering and empty-match guarantees** — `2f77d84` (test)

**Plan metadata:** see the `docs(01-02)` commit following this file.

## Files Created/Modified

- `src/platform/core.pinc` — `walk_upstreams` lifted to module level above `GetConfigs`' doc comment; `SelectComponents` added beside it; `WithLabels` added after `WithFailureDomain`. Each carries a rationale block comment naming the rejected alternative.
- `src/platform/platform.pinc` — `"SelectComponents"` and `"WithLabels"` in the alphabetised load list; `SelectComponents` beside `GetConfigs` and `WithLabels` beside `WithFailureDomain` in the `platform` struct.
- `test/src/select_test.mpconf` — the assertion probe: a `top -> {mid1, mid2} -> leaf` diamond plus an unlabelled `base`, four selections asserted against literal lists, `main()` returning `{}`.
- `.planning/REQUIREMENTS.md` — FOUND-02 renamed to `platform.v1.Component.Metadata.labels`.
- `.planning/ROADMAP.md` — Phase 1 success criterion 2 and the two Overview references renamed.

## Decisions Made

- **De-duplicate by structural equality, not by a string key.** `Component` builds each dependency once per parent, so a diamond's shared upstream is two distinct objects with equal content. Proto messages hash and compare by value here, so a `dict` collapses exactly that case; identity comparison collapses nothing, and a `<domain>/<name>` key would work while silently asserting a uniqueness the schema does not enforce.
- **`WithLabels` does not inherit.** D-09. Whether a label should reach a component's whole dependency subtree is a Phase 2 (COST-01) question, and `WithFailureDomain` shows the inheriting variant is a one-word change.
- **`SelectComponents` returns `[]` rather than failing on no match.** Phase 5's SEC-02 needs the empty result in order to raise its own, better-informed error.
- **The `fail()` prefix `SelectComponents: expected ` is load-bearing.** It is the only string a tripped assertion emits that an unrelated failure in the same file — syntax error, missing load, NoneType field access — does not, which is what makes the negative check distinguish "the assertion fired" from "the file did not compile."

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Task 2's negative-check command needs `bash`, not this repo's login shell**
- **Found during:** Task 2 (negative check)
- **Issue:** The check as written does `sed ... > src/select_test.mpconf`. Under zsh with `noclobber` set, the redirect is refused with `file exists: src/select_test.mpconf`, and the `cp` restore prompts interactively because `cp` is aliased to `cp -i`. The net effect was a false PASS shape: the mutation was never written, `protoconf compile .` ran against the unmutated file and exited 0, so the gate reported "the assertion did not fire" when in fact nothing had been mutated.
- **Fix:** Ran the identical command under `bash -c`. No change to the assertion, the mutation, or the file.
- **Files modified:** none
- **Verification:** `compile_rc=1` and the log carries `[select_test.mpconf:96:13] SelectComponents: expected the two tier=app components in post-order, ['mid1', 'mid2'], got ["leaf", "mid1", "mid2"]`. The worktree was clean afterwards.
- **Committed in:** n/a (no file change)

---

**Total deviations:** 1 auto-fixed (1 blocking).
**Impact on plan:** None on the shipped artifacts. Worth recording because the failure mode was a silent false negative on a verification gate — a check that reports "did not fire" when it never ran the mutation is exactly the shape of guard this phase exists to remove. Anyone re-running the plan's third Task 2 gate on a zsh host should invoke it under `bash`.

## TDD Gate Compliance

Task 2 carries `tdd="true"`, and the RED gate did not take its usual chronological form: the implementation it asserts shipped in Task 1 of the same plan, so a committed failing test before the feature was not available. Per the fail-fast rule, the probe was not simply accepted because it passed. RED was established by mutation instead, and the evidence is stronger than a first-run failure: relabelling the leaf so it no longer distinguishes itself makes `protoconf compile .` exit 1 emitting the probe's own `SelectComponents: expected` prefix, proving the assertion fires and is not vacuous. Gate commits present: `feat(01-02)` `e095f56` (GREEN), `test(01-02)` `2f77d84`. No REFACTOR commit — none was needed.

## Issues Encountered

None beyond the deviation above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- **Ready for 01-03** (FOUND-04/05 compile-time enforcement in the `github_actions` driver, plus the redis `BACKEND` fix). That plan is the one place in Phase 1 where a non-empty golden diff is correct (D-16); everything this plan touched diffs empty, so any golden change 01-03 produces is unambiguously its own.
- **Phase 2 (COST-01)** inherits a live question this plan deliberately left open: whether a cost-centre label should propagate to a component's dependency subtree. `WithFailureDomain` is the precedent and the change is `return Inherit(component_filter(do))`.
- **Phase 5 (SEC-01/02)** can now be planned against a field that exists and a selector that is asserted on every build. `SelectComponents` returning `[]` on no match is the behaviour SEC-02 was planned to build its own error on.
- **Stated assumption, unresolved:** `WithLabels()` with no keyword arguments constructs an empty `Metadata` and writes nothing. Nothing in ROADMAP, REQUIREMENTS, CONTEXT or RESEARCH says what it should do. Harmless today — a `Component` is never materialized — but if Phase 2 wants it to be an error, that is a Phase 2 decision.

## Self-Check: PASSED

- `test/src/select_test.mpconf` — FOUND on disk.
- `src/platform/core.pinc`, `src/platform/platform.pinc`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md` — FOUND on disk.
- Commit `e095f56` — FOUND in `git log`.
- Commit `2f77d84` — FOUND in `git log`.
- All five Task 1 `<automated>` gates and all three Task 2 `<automated>` gates re-run: PASS.
- Plan-level verification 1-4: PASS (`make test` exit 0, empty diff on all three drift-asserted trees, probe materializes nothing, drift workflow's own assertion is the same command and holds).

---
*Phase: 01-trustworthy-foundations*
*Completed: 2026-09-07*
