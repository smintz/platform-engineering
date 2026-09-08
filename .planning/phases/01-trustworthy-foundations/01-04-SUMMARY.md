---
phase: 01-trustworthy-foundations
plan: 04
subsystem: testing
tags: [make, protoconf, starlark, ci, terraform, github-actions, mutation-testing]

# Dependency graph
requires:
  - phase: 01-03
    provides: "the two compile gates (`_check_remote_backends`, `_check_reads_are_produced`) and the handshake fixture with its two named switch points"
provides:
  - "`make gates` — a committed command that deletes each compile gate's effect and fails if the gate stays quiet"
  - "gate-fired determination by the compiler's own message plus the gate function named in the traceback, never by exit code"
  - "a landing check per mutation, so a broken sed anchor reports itself instead of reading as a dead gate"
  - "coverage of both negative checks in `.github/workflows/drift.yaml` with no workflow edit — the target rides `make test`"
  - "fixture prose that names a command that exists and the function that actually catches each mutation"
affects: [phase-02-cost, phase-03-data, phase-05-security, any phase adding a compile gate to the CI driver]

actuals:
  tokens: 1951
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "Negative checks as a make target: mutate a COPY of a committed fixture, compile it, assert on the compiler's message — the tracked file is never the file mutated"
    - "Assert on message + traceback function name, never exit code, when the mutation has other reasons to exit non-zero"
    - "Confirm the mutation landed before interpreting the compile it produced"

key-files:
  created: []
  modified:
    - test/Makefile
    - test/src/handshake_test.mpconf

key-decisions:
  - "The gates target compiles mutated COPIES (`src/gate04_probe.mpconf`, `src/gate05_probe.mpconf`) rather than mutating the tracked fixture in place — diverging from 01-REVIEW.md CR-02's sketch, whose sed -i plus /tmp restore leaves the tracked fixture modified if the compile is interrupted"
  - "Gate-fired is decided by the gate's fail() message AND the gate function in the traceback, never by exit code — measured: with both gates deleted the LOCAL mutation still exits 1 from the duplicate-state fail() in _producers at github_actions.pinc:125"
  - "Each substitution is confirmed landed (anchored grep on the copy) before its compile is interpreted — a check that cannot tell 'gate did not fire' from 'mutation was never written' proves nothing"
  - "`$(MAKE) gates` runs LAST in `test`, after `workflows` — a red gate should not also leave the contributor a stale tree to explain"
  - ".github/workflows/drift.yaml deliberately NOT edited: it already runs `cd test && make test`, and a second CI step would put the check in two places that can disagree"

patterns-established:
  - "Mutation-testing a compile gate: sed a copy, confirm it landed, compile with `|| true` on the COMPILE only, assert on the message and the traceback function"
  - "One backslash-continued shell invocation per recipe so a single `trap ... EXIT` covers every exit path — make runs each recipe line in its own shell"
  - "No escape hatches on a guard: no `-` recipe prefix, no `|| true` on an assertion, no SKIP variable; the Makefile is grepped for all three"

requirements-completed: [FOUND-04, FOUND-05]

coverage:
  - id: D1
    description: "`make gates` reproduces both negative compile checks from the committed fixture and exits 0 printing `gates: both compile gates fired` on an unmodified checkout"
    requirement: "FOUND-04"
    verification:
      - kind: integration
        ref: "cd test && /usr/bin/make gates"
        status: pass
    human_judgment: false
  - id: D2
    description: "Deleting either compile gate is now a red build: with `_check_remote_backends(configs)` and `_check_reads_are_produced(configs)` both replaced by `pass`, `make test` exits non-zero and prints a `gate did not fire` line — the exact mutation that gave exit 0 in 01-VERIFICATION.md"
    requirement: "FOUND-05"
    verification:
      - kind: integration
        ref: "sed both gate calls to `pass` (mutation confirmed by grep -c '^    pass$' == 2), then cd test && /usr/bin/make test — exit 2, output contains `gates: FOUND-04 gate did not fire`"
        status: pass
    human_judgment: false
  - id: D3
    description: "The target decides gate-fired from the compiler's message and the traceback function, never from the exit code, and confirms each substitution landed before interpreting the compile"
    requirement: "FOUND-04"
    verification:
      - kind: integration
        ref: "grep test/Makefile for all four assertion substrings, both anchored landing patterns, `substitution did not land` exactly twice, zero `grep ... || true`, zero `^\\t-` recipe lines (comment lines stripped first)"
        status: pass
    human_judgment: false
  - id: D4
    description: "`make gates` never edits a tracked file and leaves no probe copy behind — idempotent across consecutive runs"
    requirement: "FOUND-05"
    verification:
      - kind: integration
        ref: "git status --porcelain byte-identical before and after two consecutive `make gates` runs; `git status --porcelain -- test/src` empty after every run including the failing one"
        status: pass
    human_judgment: false
  - id: D5
    description: "CI covers both negative checks with no edit to `.github/workflows/drift.yaml` — the coverage arrives through the `make test` the workflow already runs"
    verification:
      - kind: integration
        ref: "cd test && /usr/bin/make test — recipe output shows `make gates` / `gates: both compile gates fired`; drift.yaml byte-identical to HEAD"
        status: pass
    human_judgment: true
    rationale: "Proven locally on darwin/arm64 with a locally-built protoconf 0.0.1. drift.yaml pins 0.2.0-rc2 on linux_amd64 and has never executed on GitHub (assumption A1, 01-RESEARCH.md, still open). The wiring is proven; the runner has not run it."
  - id: D6
    description: "`test/src/handshake_test.mpconf` names the command that exercises `MISMATCHED`/`LOCAL` and the function that catches each mutation, replacing a pointer to a plan task and a wrong-gate attribution"
    verification:
      - kind: integration
        ref: "grep the fixture: `make gates` present, both gate function names present, `this plan's Task 3` count 0, `print(` count 0; git diff shows changes only on `#` comment lines"
        status: pass
    human_judgment: false

# Metrics
duration: 4 min
completed: 2026-09-08
status: complete
---

# Phase 01 Plan 04: Gate Defence Summary

**`make gates` — a Makefile target that mutates a copy of the handshake fixture per compile gate and asserts on the gate's own `fail()` message plus the traceback function name, turning gate deletion from a green build into a red one.**

## Performance

- **Duration:** 4 min
- **Started:** 2026-09-08T02:53:56Z
- **Completed:** 2026-09-08T02:58:33Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- **Gap 2 from 01-VERIFICATION.md is closed.** That report replaced both gate calls in `TerraformPipeline` with `pass` and measured `cd test && make test` at exit **0** and drift.yaml's own assertion at exit **0** — the phase's headline guarantee (ROADMAP SC-3, SC-4) deletable with nothing noticing. The same mutation now gives `make test` exit **2** and the line `gates: FOUND-04 gate did not fire — _check_remote_backends did not report a local backend`.
- **The determination does not rest on exit code.** Re-measured during execution: with both gates deleted, the FOUND-04 mutation still exits 1, from the duplicate-state `fail()` in `_producers` at `github_actions.pinc:125`, with no gate message at all. An exit-code assertion would have reported a gate that no longer exists as firing. The target compiles with `|| true` on the compile and asserts on `writes local Terraform state` + `_check_remote_backends` and on `which no config in this pipeline writes` + `_check_reads_are_produced`.
- **A broken anchor reports itself.** Each mutation is confirmed landed with an anchored `grep -q '^NEAR_BACKEND = LOCAL$'` / `'^FAR_BACKEND = MISMATCHED$'` on the copy before the compile is read. Without it, a fixture edit that breaks the sed anchor produces a copy identical to the original, which compiles clean, which reads exactly like a gate that stopped firing.
- **No CI edit.** `test` invokes `$(MAKE) gates` last, and `.github/workflows/drift.yaml` already runs `cd test && make test`. The workflow is byte-identical to HEAD.
- **The tracked fixture is never mutated.** Both probes are copies under `test/src/`, removed by one `trap ... EXIT` covering every exit path — including the failing falsification run, after which `git status --porcelain -- test/src` was empty.
- **`MISMATCHED` and `LOCAL` stopped being constants kept alive by a comment.** They are now inputs to a command `make test` runs; deleting either turns the build red.
- **The wrong-gate comment is corrected.** `handshake_test.mpconf:118-124` attributed the `LOCAL` catch to `_producers`. Measured traceback: `_check_remote_backends` at `github_actions.pinc:204`, and `_producers` is never reached with the gates in place. The comment now names the right function for each mutation and keeps `_producers` as the second catcher *behind* the gate — which is the reason the target asserts on messages rather than status.

## Task Commits

1. **Task 1: `make gates` — the two negative checks become a committed command** — `c843d7c` (feat)
2. **Task 2: The fixture's prose stops describing a script that does not exist** — `210d5bc` (docs)

## Files Created/Modified

- `test/Makefile` — new `gates` target (one backslash-continued shell invocation, `set -e`, single `trap ... EXIT`); `$(MAKE) gates` appended as the last line of `test`; `gates` added to `.PHONY`; prose block naming the silent failure prevented
- `test/src/handshake_test.mpconf` — comments only, three regions: header now names `make gates` instead of "this plan's Task 3"; the `MISMATCHED`/`LOCAL` preamble names the command that consumes them and records that the two switch-point assignments are anchored substitution targets; the `main()` ordering rationale names the correct catcher per mutation

## Decisions Made

- **Compile copies, not the tracked file.** 01-REVIEW.md CR-02's sketch does `cp` to `/tmp`, `sed -i` the tracked fixture, then restore. An interruption between mutation and restore leaves `test/src/handshake_test.mpconf` modified in the contributor's tree. Redirecting `sed` into a new file under `src/` removes the restore step entirely — there is no half-applied state to recover from, only a copy to delete.
- **Fixed probe filenames, not `mktemp`.** `protoconf compile` resolves entry points relative to `src/`, so the copies must live there; a fixed name keeps the `trap` and the compile argument in agreement. The cost is that two concurrent `make gates` runs in one worktree collide — which surfaces as a compile error naming a missing or half-written probe, never as a green run that skipped a gate.
- **`|| true` on the compile only.** The compile's non-zero exit is expected and is not the assertion. No `grep` in the recipe carries `|| true`, no recipe line carries a `-` prefix, and there is no skip variable — the Makefile is grepped for all three over comment-stripped lines.
- **`$(MAKE) gates` last in `test`.** After `workflows`, so a red gate does not also leave a stale generated tree to explain.
- **drift.yaml untouched.** A second CI step would put the check in two places that can disagree.

## Deviations from Plan

None - plan executed exactly as written.

Every pinned literal was preserved verbatim: both sed expressions, both anchored landing patterns, all four assertion substrings, the `substitution did not land` phrasing (exactly twice, unbroken on one line each), and the `gates: both compile gates fired` success line. `protoconf fmt -d` on the edited fixture showed an empty diff before `-w` was run, so formatting changed nothing.

## Issues Encountered

- The interactive shell has `noclobber` set, so re-running a `<verify>` command whose `> /tmp/...log` target already existed failed with `file exists`. An artifact of the executing shell, not of the deliverable — the commands pass when the stale log is removed first, and the recipe's own redirections run under `/bin/sh` inside make, unaffected.

## Threat Flags

None. No new network endpoint, auth path, or schema change. The only new paths that ever exist on disk are the two probe copies, already carried as T-01-G4 (`accept`) in the plan's threat register, and neither survives the target that creates it.

## Known Stubs

None.

## Verification Results

Plan-level `<verification>`, all five run post-commit:

| # | Check | Result |
|---|-------|--------|
| 1 | `cd test && make test` exits 0; the three drift-asserted trees diff empty | PASS (RC=0, empty diff) |
| 2 | `cd test && make gates` prints `gates: both compile gates fired` | PASS |
| 3 | Both gate calls replaced by `pass` → `make test` exits non-zero and prints `gate did not fire` | PASS (RC=2, `gates: FOUND-04 gate did not fire — _check_remote_backends did not report a local backend`) |
| 4 | `git status --porcelain` byte-identical before and after every run above | PASS |
| 5 | `github_actions.pinc`, `drift.yaml`, `test/outputs/`, `test/materialized_config/` unchanged from HEAD | PASS |

Task 1's five `<automated>` checks and Task 2's three all passed on first run; both tasks' `<acceptance_criteria>` were re-checked individually, including the two not covered by an automated command (no `sed -i` in the recipe; `actions.TerraformPipeline` still precedes `actions.dependencies` in `main()`), and the comment-only constraint (`git diff -U0` produced no changed line outside `#` comments).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- ROADMAP SC-3 and SC-4 are now held by a committed command rather than a comment. Any future phase adding a gate to the CI driver has a pattern to copy: mutate a fixture copy, confirm the mutation landed, assert on the message and the traceback function.
- **Phase 01 gap 1 remains open** — `SelectComponents` de-duplicates by proto value and returns one of two live objects on a diamond. That is 01-05-PLAN's scope, and it is the gap Phase 5 SEC-01 and Phase 2 COST-01 depend on.
- **Assumption A1 still open and unwidened by this plan.** `drift.yaml` has never executed on GitHub; golden-file byte-reproducibility was measured only on darwin/arm64 against a locally-built protoconf 0.0.1 while CI pins 0.2.0-rc2 on linux_amd64. `make gates` inherits that assumption but does not extend it — it asserts on message text, not generated bytes, so a compiler that disagrees about whitespace still reports the same gate messages.

## Self-Check: PASSED

- `test/Makefile` — FOUND on disk
- `test/src/handshake_test.mpconf` — FOUND on disk
- Commit `c843d7c` — FOUND in git log
- Commit `210d5bc` — FOUND in git log

---
*Phase: 01-trustworthy-foundations*
*Completed: 2026-09-08*
