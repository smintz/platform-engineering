---
phase: 01-trustworthy-foundations
plan: 05
subsystem: platform-core
tags: [starlark, protoconf, graph-traversal, selector, component-model]

# Dependency graph
requires:
  - phase: 01-trustworthy-foundations (01-02)
    provides: "`walk_upstreams` lifted to module level, `SelectComponents`, `WithLabels`, and the `select_test.mpconf` fixture this plan rewrites"
  - phase: 01-trustworthy-foundations (01-04)
    provides: "`make test` also runs `make gates`, so this plan's verification rides the same target"
provides:
  - "`platform.SelectComponents(root, predicate)` returns EVERY occurrence of a matching component, so a hook applied across the result reaches every live object in the graph"
  - "Selection idempotent with respect to mutation: the same list before and after mutating through it"
  - "A committed fixture that stamps every returned component and reads the value back through a walk independent of `SelectComponents`"
  - "`walk_upstreams(component, visit)` — the visitor parameter named for what it is, not for this repo's hook-chain `next`"
affects: [phase-02-cost-attribution, phase-05-security-hardening, COST-01, SEC-01, SEC-02, SEC-03]

# Actuals (#2632)
actuals:
  tokens: 3400
  tasks: 2
  commits: 2

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A fixture that verifies a selector must read its result back through an observer independent of that selector"
    - "Occurrence, not content-identity, is the unit a graph selector returns"

key-files:
  created: []
  modified:
    - src/platform/core.pinc
    - test/src/select_test.mpconf

key-decisions:
  - "Task 1 resolved `every-occurrence`: SelectComponents returns every occurrence of a matching component in the graph, superseding D-11's de-duplication clause and 01-02-PLAN's de-dup must_have"
  - "`walk_upstreams`' second parameter renamed `next` -> `visit`, superseding 01-02-PLAN's acceptance criterion naming `walk_upstreams(component, next)`"
  - "D-11's prohibition on a `\"<domain>/<name>\"` uniqueness key is NOT superseded — no such key was added and no de-duplicating helper was exported"

patterns-established:
  - "Independent read-back: a check that asks whether a mutation through an API reached the live objects must observe those objects through a walk the API does not own — otherwise a component the API omits is omitted in both directions and the check passes on the defect"
  - "`len(` is prohibited in this fixture: a count assertion passes on two objects neither of which the mutation reached"

requirements-completed: [FOUND-03]

coverage:
  - id: D1
    description: "`platform.SelectComponents(root, predicate)` returns every occurrence of a matching component in a diamond, in `walk_upstreams`' post-order"
    requirement: "FOUND-03"
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#post-order assertion — ['leaf','base','mid1','leaf','mid2','top']"
        status: pass
      - kind: integration
        ref: "test/src/select_test.mpconf#tier=cache assertion — ['leaf','leaf']"
        status: pass
      - kind: integration
        ref: "cd test && make test"
        status: pass
    human_judgment: false
  - id: D2
    description: "A mutation applied across the selection reaches BOTH embedded leaf objects — the property Phase 5 SEC-01 and Phase 2 COST-01 consume"
    requirement: "FOUND-03"
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#stamp-and-read-back assertion via occurrences(root, []) — [STAMP, STAMP]"
        status: pass
      - kind: integration
        ref: "mutation-falsification: restoring `found = {}` / `found[c] = True` / `found.keys()` makes `protoconf compile . select_test.mpconf` exit 1 with a traceback naming select_test.mpconf:111"
        status: pass
    human_judgment: false
  - id: D3
    description: "Selection is idempotent with respect to mutation — the same list before and after mutating through it (was 1 then 2)"
    requirement: "FOUND-03"
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#idempotency assertion — ['leaf','leaf'] after stamping"
        status: pass
    human_judgment: false
  - id: D4
    description: "FOUND-03 empty and single-element edges: a predicate nothing matches returns [] without failing; a root with no upstreams that matches returns exactly itself"
    requirement: "FOUND-03"
    verification:
      - kind: integration
        ref: "test/src/select_test.mpconf#no-such-tier assertion — [] ; #BaseComponent().msg assertion — ['base']"
        status: pass
    human_judgment: false
  - id: D5
    description: "`GetConfigs` output unchanged — `test/materialized_config/`, `test/outputs/` and `.github/workflows/terraform.yaml` byte-identical after a full rebuild (D-12)"
    verification:
      - kind: integration
        ref: "git add -AN -- test/materialized_config test/outputs .github/workflows/terraform.yaml && git diff --exit-code"
        status: pass
    human_judgment: false
  - id: D6
    description: "`walk_upstreams(component, visit)` — visitor parameter renamed from `next`, both call sites still positional, still one traversal with two consumers (D-10)"
    verification:
      - kind: integration
        ref: "grep -cE '^[[:space:]]+walk_upstreams\\(component, ' src/platform/core.pinc == 2 ; grep -qE '^def walk_upstreams\\(component, visit\\):$'"
        status: pass
    human_judgment: false

# Metrics
duration: 4 min
completed: 2026-09-08
status: complete
---

# Phase 01 Plan 05: SelectComponents Returns Every Occurrence Summary

**`platform.SelectComponents` returns every occurrence rather than collapsing a diamond's two distinct live objects into one, with a fixture that stamps through the selection and reads the result back through a walk of its own.**

## Performance

- **Duration:** 4 min
- **Started:** 2026-09-08T03:19:35Z
- **Completed:** 2026-09-08T03:23:13Z
- **Tasks:** 2 (1 decision checkpoint, 1 implementation)
- **Files modified:** 2

## Accomplishments

- `SelectComponents` collects into a list (`found.append(c)`) instead of a value-keyed dict, so both live `leaf` objects reached down the two arms of the `top -> {mid1, mid2} -> leaf` diamond are returned. Measured `['leaf', 'leaf']`; previously `['leaf']`.
- Selection is now idempotent with respect to mutation: `['leaf','leaf']` before and after stamping every returned component. Before this plan it returned 1 then 2, because the dict keyed on proto value and the mutation made the two contents differ — the answer depended on the graph's mutation history.
- `test/src/select_test.mpconf` grew the assertion the gap existed for: it stamps `description = STAMP` on every returned `tier=cache` component and reads the leaf descriptions back through `occurrences(root, [])`, a walk written in the fixture and independent of `SelectComponents`. Result `["POLICY-APPLIED", "POLICY-APPLIED"]`.
- The comment above `SelectComponents` no longer argues for the retired behaviour. It states why every occurrence is returned, that the previous collapse was neither complete nor idempotent, and that a caller wanting a unique view builds one from a key it chose.
- `walk_upstreams`' second parameter renamed `next` -> `visit`. Both call sites are positional and unchanged; D-10's one-traversal-two-consumers property holds.
- `GetConfigs` untouched and its output byte-identical (D-12).

## Task Commits

1. **Task 1: Decide what SelectComponents returns for a diamond** — checkpoint, no commit (decision recorded below)
2. **Task 2: SelectComponents returns every occurrence, and the fixture proves a mutation reaches both arms** — `63dd041` (feat)

## Files Created/Modified

- `src/platform/core.pinc` — `SelectComponents` collects into a list and returns it; its rationale comment rewritten; `walk_upstreams`' second parameter renamed `next` -> `visit` with the reason stated above the `def`.
- `test/src/select_test.mpconf` — `STAMP` constant, `occurrences(component, out)` independent walk, post-order and `tier=cache` assertions updated to the measured values, plus three new assertions (single-element, mutation reachability, idempotency).

## Task 1 Decision — recorded verbatim

**Option selected: `every-occurrence`**

**Reason, as given:**

> the behaviour D-11 described ("one component returned once") is not the behaviour the code has — it drops one of two live objects by a first-insertion-wins accident and stops dropping it once anything mutates the graph, so preserving it would preserve a defect under the name of a decision. Both planned consumers (Phase 2 COST-01, Phase 5 SEC-01) apply a hook across a selection and need every occurrence reached, and Phase 5 SEC-03 audits which components each policy hit from an artifact built on this selector.

This was a human decision at the blocking checkpoint in Task 1, not an executor judgement. It reverses a truth 01-02-PLAN published, which is why the reversal is recorded here rather than left implicit.

### Superseded by this decision

| Source | Statement | Superseded by |
|---|---|---|
| `01-02-PLAN.md` `must_haves.truths` | "Two components with identical content collapse to a single entry: a component reached down two arms of a diamond is returned once, not twice (D-11)." | Task 1's checkpoint decision (`every-occurrence`) |
| `01-02-PLAN.md` `acceptance_criteria` | "`src/platform/core.pinc` defines `walk_upstreams(component, next)` at module level" | Task 2 step 3, under 01-CONTEXT.md "Claude's Discretion" ("whether `walk_upstreams` keeps its `next`-callback shape") |
| `01-CONTEXT.md` D-11 | "returning a list ... de-duplicated by component identity" | Task 1's checkpoint decision (`every-occurrence`) |

### NOT superseded

**D-11's prohibition on a `"<domain>/<name>"` key stands and is honoured.** No such key exists anywhere in `src/platform/core.pinc`, and no de-duplicating helper was exported — the user selected `every-occurrence`, not `occurrence-plus-unique`. Such a key would assert a uniqueness `src/platform/v1/platform.proto` does not enforce, and exporting a helper built on it would make that assertion the platform's rather than the caller's (threat T-01-S6). A caller that genuinely wants a unique view builds one, visibly, at its own call site.

`01-01-PLAN.md`, `01-02-PLAN.md` and `01-03-PLAN.md` were not edited.

## Decisions Made

- **`every-occurrence`** (human, Task 1 checkpoint) — see the verbatim record above.
- **Rename `next` -> `visit` in `walk_upstreams`** — the repo-wide `next` means "call the next hook and return its result"; this function discards every recursive return value, so the name told every reader the opposite of what the code does. Granted explicitly by 01-CONTEXT.md under "Claude's Discretion".
- **Assertions written before the implementation.** The fixture was committed to disk first and compiled against the unchanged `SelectComponents`; it failed at `select_test.mpconf:111` naming the post-order assertion, which is how the check was proven to discriminate before the code it checks was touched.

## Verification Results

| # | Check | Result |
|---|---|---|
| 1 | `cd test && make test` exits 0 and prints `gates: both compile gates fired` | PASS |
| 2 | `test/materialized_config/`, `test/outputs/`, `.github/workflows/terraform.yaml` diff empty after full rebuild (D-12) | PASS |
| 3 | `core.pinc` shape: `SelectComponents(component, predicate)` signature intact, `found.append(c)` exactly once, `walk_upstreams(component, visit)`, no `found[c] = True`, no `found.keys()`, exactly two `walk_upstreams(component, ` call sites, no `print(`, facade and schema unchanged | PASS |
| 4 | Fixture shape: measured six-element post-order literal, `POLICY-APPLIED`, `def occurrences(component, out):`, `BaseComponent().msg`, `occurrences(root` used, `len(` absent | PASS |
| 5 | Mutation-falsification: reverting to `found = {}` / `found[c] = True` / `found.keys()` (all three landings confirmed present exactly once first) makes `protoconf compile . select_test.mpconf` exit 1 with a traceback naming `select_test.mpconf:111` | PASS |
| 6 | `src/platform/platform.pinc` unchanged; `git status --porcelain -- test/src` empty (no scratch probe left behind) | PASS |

Pre-implementation RED observation: with the fixture written and `core.pinc` untouched, `protoconf compile . select_test.mpconf` failed with `got ["leaf", "base", "mid1", "mid2", "top"]` — the missing second `leaf`, exactly the gap 01-VERIFICATION.md recorded.

## Deviations from Plan

None — plan executed exactly as written. The pinned literals (`found.append(c)`, the `^[[:space:]]+` anchor in verify #3, the post-order list `['leaf','base','mid1','leaf','mid2','top']`, and verify #5's three-way landing guard) were used verbatim.

`01-VERIFICATION.md`'s proposed post-order `['leaf','base','mid1','mid2','leaf','top']` was NOT used; the plan's measured list was, and the compiler confirmed it (the fixture is green and the falsification is red).

## Issues Encountered

- **Interactive-shell `noclobber` truncated a verify step, not the code.** Verify #5's `cat "$T/core.bak" > "$F"` restore was refused with `file exists`, leaving `src/platform/core.pinc` in the deliberately-reverted state after the falsification ran. Caught immediately by grepping the file, restored by applying the exact inverse of the three substitutions, and the falsification was re-run with `>|` — the restored file hashes identical to the pre-falsification version and `make test` is green. The repo's `<repo_notes>` warns about this; it applies to `>` on any existing path, not only to `/tmp/*.log`.

## Next Phase Readiness

- FOUND-03 is closed and ROADMAP SC-2 is true: a platform author writes a predicate over `Component.Metadata.labels`, calls the exported `SelectComponents`, and can act on every matching component in the graph.
- Phase 2 COST-01 and Phase 5 SEC-01 can now apply a hook across a selection and reach every live object. Phase 5 SEC-03's audit artifact has a selector that does not under-report.
- Known consequence, recorded rather than discovered later: a caller applying a NON-idempotent hook across a selection now applies it once per occurrence rather than once per distinct component (threat T-01-S5, accepted). Nothing in phases 2-5 is planned that way.
- Phase 01 has one more plan's worth of verification surface: 01-VERIFICATION.md's remaining gaps are not this plan's.

---
*Phase: 01-trustworthy-foundations*
*Completed: 2026-09-08*

## Self-Check: PASSED

- `src/platform/core.pinc` — exists on disk
- `test/src/select_test.mpconf` — exists on disk
- `.planning/phases/01-trustworthy-foundations/01-05-SUMMARY.md` — exists on disk
- Commit `63dd041` (Task 2, feat) — present in git log
- Commit `c2070ad` (SUMMARY, docs) — present in git log
- All six plan `<verify>` clauses re-run and PASS (table above)
