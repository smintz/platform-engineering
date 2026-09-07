---
phase: 01-trustworthy-foundations
verified: 2026-09-08T01:20:00Z
status: gaps_found
score: 3/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: none
  previous_score: n/a
  note: "Initial verification. A code review (01-REVIEW.md) ran immediately before; its CR-01/CR-02/CR-03 leads were re-tested independently — CR-01 and CR-02 confirmed by live probe, CR-03 partially refuted and partially confirmed."
gaps:
  - truth: "A platform author can write a predicate over Component.Metadata.labels and call the exported SelectComponents to retrieve every component in a dependency graph matching it (ROADMAP SC-2, FOUND-03)"
    status: failed
    reason: "SelectComponents de-duplicates by proto VALUE (`found[c] = True`). Component builds each dependency factory once per parent, so a diamond holds two DISTINCT objects with equal content. The dict collapses them, the caller receives exactly one of the two live objects, and which one survives is a first-insertion-wins artifact of walk_upstreams' order. Proven by independent probe, not inferred: a top->{mid1,mid2}->leaf diamond returned 1 leaf; mutating it left mid2's leaf at \"\"; re-selecting after that mutation returned 2. The function is therefore neither complete nor idempotent, and this is precisely the mutate-across-a-selection use case Phase 5 SEC-01 and Phase 2 COST-01 are planned against."
    artifacts:
      - path: "src/platform/core.pinc:211-229"
        issue: "`found = {}` / `found[c] = True` / `return found.keys()` — value-keyed de-duplication over a graph that stores copies. The docstring's justification (\"a component reached down two arms of a diamond is one component\") is false for this graph: they are two objects, and a hook applied to the returned one does not reach the other."
      - path: "test/src/select_test.mpconf:96-115"
        issue: "Asserts only on `c.name`. Never mutates a returned component and never re-selects, so it passes on the broken behaviour and cannot catch a regression in either direction."
    missing:
      - "Return every occurrence in post-order (drop the dict), so a caller reaches every live object; update select_test.mpconf's first assertion to ['leaf','base','mid1','mid2','leaf','top']."
      - "A committed assertion that mutating the selection reaches BOTH embedded `leaf` objects — the property SEC-01 depends on."
      - "If a de-duplicated view is genuinely wanted, build it on top from an explicit \"<domain>/<name>\" key where the uniqueness assumption is visible, rather than from value equality."
  - truth: "Both compile gates are proven to FIRE, not merely to exist, by a committed probe with two named switch points and two scripted negative checks (01-03-PLAN must_haves)"
    status: failed
    reason: "The probe is committed; the scripts are not. Confirmed by falsification, not by reading: replacing both gate calls in TerraformPipeline with `pass`, then running `cd test && /usr/bin/make test` gave exit 0, and the drift workflow's own assertion (`git add -A -- <3 pathspecs>; git diff --cached --exit-code`) gave exit 0. The phase's headline guarantee — the two guards behind ROADMAP SC-3 and SC-4 — can be deleted with no committed check noticing. `git ls-files` finds no project shell script; test/Makefile has exactly `test` and `workflows`; drift.yaml runs `make test` only."
    artifacts:
      - path: "test/src/handshake_test.mpconf:26"
        issue: "\"those two negative checks are scripted from outside the compiler rather than asserted here — see this plan's Task 3\". No such script exists in the repository."
      - path: "test/src/handshake_test.mpconf:41-64"
        issue: "`MISMATCHED` and `LOCAL` are unreferenced module constants. Their comment forbids deleting them as dead code because they feed the negative checks — but nothing runs those checks, so they currently guard nothing."
      - path: "test/Makefile:1-10"
        issue: "One target and one helper. No `gates` target, so the negative checks are not reachable by any committed command."
      - path: ".github/workflows/drift.yaml:60-61"
        issue: "Runs `cd test && make test` only — a green drift run says nothing about whether either gate still fires."
    missing:
      - "A committed `gates` target in test/Makefile that substitutes LOCAL into NEAR_BACKEND and MISMATCHED into FAR_BACKEND, confirms each mutation landed before compiling, and asserts on the gate's own MESSAGE (not the exit code — both mutations exit non-zero for several reasons)."
      - "That target invoked from `make test`, so drift.yaml covers it without a second CI step."
deferred: []
human_verification:
  - test: "Open a pull request that touches test/src/** and let .github/workflows/drift.yaml run on GitHub for the first time."
    expected: "The workflow installs protoconf 0.2.0-rc2 (sha256 verified), runs `cd test && make test`, and the diff over the three asserted trees is empty on an already-current tree."
    why_human: "The workflow has never executed. Golden-file byte-reproducibility was measured only on darwin/arm64 with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64. If those two compilers disagree by a byte, every PR goes red or — worse — a contributor's local build gets accepted where CI would have written different bytes. This is assumption A1 in 01-RESEARCH.md, still open, and no local check can close it."
  - test: "Decide whether SelectComponents' value-de-duplication is acceptable, given that Phase 5 SEC-01 and Phase 2 COST-01 both apply a hook across a selection."
    expected: "Either the gap above is closed before Phase 2, or an `overrides:` entry records the decision to keep collapse-by-value."
    why_human: "The implementation matches 01-02-PLAN's own must_have truth (\"a component reached down two arms of a diamond is returned once, not twice\"), so this is a specification-level decision, not an execution slip. D-07's own reversibility argument applies verbatim: cheap to change now, expensive once four fan-outs select against it."
  - test: "Decide whether the drift check must cover a renamed or added generated workflow (CR-03)."
    expected: "Either the pathspec and trigger widen from the literal .github/workflows/terraform.yaml to .github/workflows/**, and `make workflows` prunes what it no longer generates, or the risk is accepted."
    why_human: "The failure needs a committed rename to reproduce, which this verification would not do to the repository. The reasoning is mechanical and the consequence is a live root workflow carrying `terraform apply -auto-approve` behind a daily cron."
---

# Phase 1: Trustworthy Foundations Verification Report

**Phase Goal:** The platform's own build and cross-state wiring are trustworthy enough to build four new stakeholder fan-outs on top of
**Verified:** 2026-09-08T01:20:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Method

Every finding below was produced by executing code in this checkout, not by reading SUMMARY.md.
The repository was left byte-identical to its starting state: `cd test && /usr/bin/make test`
exits 0 and `git status --porcelain` shows only the pre-existing `.planning/` modifications
that were present before verification began. Every mutation used to falsify a claim was
confirmed to have landed (by `grep` on the mutated file) before the resulting compile was
interpreted — a check that cannot tell "assertion did not fire" from "mutation was never
written" proves nothing.

## MVP-mode note (not a gap, needs a decision)

`.planning/ROADMAP.md:38` declares `**Mode:** mvp` for this phase, but the phase goal is not a
User Story:

```
$ gsd-sdk query user-story.validate --story "<phase 1 goal>"
{ "valid": false, "errors": ["Must begin with \"As a \".", "Must contain \", I want to \".",
                             "Must contain \", so that \".", "Must end with a period."] }
```

The MVP-mode guard says to refuse verification in this case. Refusing outright would have
discarded four concrete, executable success criteria that the roadmap does supply, so this
report verifies against those instead and omits the User Flow Coverage section, which would
have been low-quality invention. If MVP mode is meant to apply here, run `/gsd mvp-phase 1` to
set a User Story goal; otherwise drop the `Mode: mvp` line.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | CI fails the build when a fresh compile differs from what's committed — a source edit without a local rebuild can no longer pass CI green (SC-1, FOUND-01) | ✓ VERIFIED | Edited `test/src/core_test.mpconf` (bucket name), rebuilt, ran drift.yaml's exact assertion from the repo root: exit **1**, 8 files listed (4 under `test/outputs/`, 4 under `test/materialized_config/`). Control run on an unmodified tree: exit **0**. `drift.yaml` parses as valid YAML, one job, `permissions: {contents: read}`, compiler pinned by version *and* sha256, error message names `cd test && make test`. Warnings below. |
| 2 | A platform author can write a predicate over `Component.Metadata.labels` and call the exported `SelectComponents` to retrieve **every** component in a dependency graph matching it (SC-2, FOUND-02/03) | ✗ FAILED | Independent probe, diamond `top -> {mid1, mid2} -> leaf`, predicate `tier == "cache"`: `pass1 count: 1`; after mutating the returned component, `mid1.leaf.description = "POLICY-APPLIED"` but `mid2.leaf.description = ""`; `pass2 count: 2`. One of two matching live objects is silently unreachable, and the answer depends on mutation history. |
| 3 | Compiling a component whose state CI will apply, but that has no remote backend configured, fails with a message naming the missing backend — no silent fallback to local state (SC-3, FOUND-04) | ✓ VERIFIED | `LOCAL` substituted for `NEAR_BACKEND` in a copy of `handshake_test.mpconf`: exit **1**, `[github_actions.pinc:204:17] TerraformPipeline: handshake/pub/infra writes local Terraform state ... Pass BACKEND as the second argument to WithState(...)`, traceback through `TerraformPipeline:670 -> _check_remote_backends`. Unmutated control copy: exit 0. Redis's live fix confirmed: `test/outputs/.../redis/infra/main.tf.json` renders `{"s3": {"region": "us-east-1", "bucket": "platform-engineering-tfstate", "key": "us-east-1/redis.tfstate"}}`. |
| 4 | Compiling a cross-state handshake CI's ordering derivation cannot see fails with a message naming the fix, rather than producing a wrong or partial apply order (SC-4, FOUND-05) | ✓ VERIFIED | `MISMATCHED` substituted for `FAR_BACKEND`: exit **1**, `[github_actions.pinc:239:17] TerraformPipeline: handshake/sub/infra reads the Terraform state s3://handshake-test-nobody-writes-this/handshake/pub.tfstate, which no config in this pipeline writes ... or pass the same backend to both halves of the handshake.`, traceback through `TerraformPipeline:671 -> _check_reads_are_produced`. The positive half (`sub -> [pub]`) is asserted by `handshake_test.mpconf` inside `make test` and IS committed. |
| 5 | Both compile gates are proven to fire by a committed probe **and two scripted negative checks** (01-03-PLAN must_have) | ✗ FAILED | Replaced both gate calls with `pass` (mutation confirmed: `grep` finds only the two `def` lines afterwards). `cd test && /usr/bin/make test` → exit **0**. drift.yaml's assertion → exit **0**. Restored and byte-compared against a backup: identical. No committed script exists (`git ls-files` finds none outside agent tooling; `test/Makefile` has no `gates` target; `drift.yaml` runs `make test` only). |

**Score:** 3/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `.github/workflows/drift.yaml` | Hand-written drift check, source-path triggered, contents:read, sha-pinned compiler | ✓ VERIFIED | Exists, 4.0K, parses. Not emitted by the driver (D-01 held). Assertion stages before diffing, so an added output file is visible. |
| root `outputs/` and `materialized_config/` | Deleted (D-05) | ✓ VERIFIED | Both absent. Exactly one generated tree remains, under `test/`. |
| `src/platform/core.pinc` — `WithLabels` | Writes `Component.Metadata.labels`, constructs `Metadata` first | ✓ VERIFIED | Lines 133-143. Nil-guard present. Probe's `metadata.labels.get("tier")` matched, so the write is real. |
| `src/platform/core.pinc` — `walk_upstreams` | Lifted to module level, one traversal, two consumers | ✓ VERIFIED | Lines 204-209 at module level; `SelectComponents:228` and `GetConfigs:255` both call it. No second traversal (D-10 held). |
| `src/platform/core.pinc` — `SelectComponents` | Returns every matching component | ⚠️ HOLLOW | Exists, substantive, wired, exported — and returns an incomplete set on a diamond. Level 4 failure: the artifact is wired but the data it hands back is missing a live object. See gap 1. |
| `src/platform/platform.pinc` | Exports `SelectComponents` and `WithLabels` through the facade (D-13) | ✓ VERIFIED | Both in the `load(...)` list and in the `platform` struct. `core.pinc` loads nothing back — module graph still acyclic. |
| `test/src/select_test.mpconf` | Committed assertion of de-dup, order and empty match | ⚠️ WEAK | Compiles under `make test` and does assert ordering and the empty case. Asserts only `c.name`, so it passes on the defect in gap 1 and would keep passing if the defect were fixed the wrong way. |
| `drivers/.../github_actions.pinc` — `_check_remote_backends` | Three branches: no backend, local backend, unnameable backend | ✓ VERIFIED | Lines 193-224. All three `fail()` branches present; the `local` branch proven to fire. |
| `drivers/.../github_actions.pinc` — `_check_reads_are_produced` | Fails on a read no config here writes | ✓ VERIFIED | Lines 230-245. Proven to fire. |
| `drivers/.../github_actions.pinc` — `_producers` | One definition, two consumers | ✓ VERIFIED | Lines 118-129; called from `dependencies:143` and `_check_reads_are_produced:231`. Built twice per pipeline (IN-03), which is a cost, not a correctness break. |
| `test/src/handshake_test.mpconf` | Ordering-edge assertion + two named switch points | ⚠️ PARTIAL | Committed and live. Switch points present. The scripts that use them are not committed — see gap 2. |
| `test/outputs/.../redis/infra/main.tf.json` + `.materialized_JSON` | S3 backend, not local (D-15/D-16) | ✓ VERIFIED | S3 block matches `BACKEND`'s `key_for`. A clean `make test` reproduces both byte-for-byte. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `test/Makefile` `test` | `.github/workflows/terraform.yaml` | `make workflows` → `cp` | ⚠️ PARTIAL | The copy works and the file is in the assertion. The copy never **prunes**: after a rename probe, `platform.yaml` and `terraform.yaml` sat side by side at the repo root *and* under `test/outputs/`. See CR-03 below. |
| `drift.yaml` `paths:` | source trees + `.github/workflows/terraform.yaml` | trigger filter | ⚠️ PARTIAL | Correctly excludes `test/outputs/**` (D-03 held). Uses the literal filename, which is `TerraformPipeline`'s overridable `name` default, and omits `test/Makefile` — the file that decides which yaml is installed. |
| `drift.yaml` `rm -f test/protoconf.lock` | `protoconf mod tidy` | pre-build step | ✓ WIRED | The committed lock holds 6 `file:///Users/smintz/...` absolute paths; the delete is the only reason CI can build at all. Lock is correctly outside the asserted diff. |
| `TerraformPipeline` | `_check_remote_backends` → `_check_reads_are_produced` → `dependencies` | call order 670, 671, 673 | ✓ WIRED | Order confirmed by source and by both tracebacks. Load-bearing and correct. |
| `GetConfigs` / `SelectComponents` | `walk_upstreams` | shared module-level function | ✓ WIRED | One traversal, two consumers. `GetConfigs` output unchanged: a full rebuild leaves the tree clean (D-12 held). |
| `handshake_test.mpconf main()` | `TerraformPipeline` before its own `dependencies` assertion | call order | ✓ WIRED | Confirmed at lines 118-139. Both mutations reach their intended gate rather than dying in the fixture's own `fail()`. |
| `SelectComponents` result | caller's mutation of a matched component | returned object identity | ✗ NOT_WIRED | The returned list holds one of two live objects. A mutation through it reaches one arm of the diamond only. |

### Data-Flow Trace (Level 4)

| Artifact | Data variable | Source | Produces real data | Status |
|----------|--------------|--------|--------------------|--------|
| `SelectComponents` | `found.keys()` | `walk_upstreams` visitor, value-keyed dict | Partially — real components, but not all of them | ⚠️ HOLLOW |
| `WithLabels` | `component.metadata.labels` | call-site kwargs | Yes — probe read `tier="cache"` back out | ✓ FLOWING |
| `dependencies(configs)` | `deps[key]` | `_producers` ∩ `_reads` | Yes — `{pub: [], sub: [pub]}` asserted live | ✓ FLOWING |
| redis `main.tf.json` | `terraform.backend.s3` | `WithState(..., BACKEND)` → `key_for` | Yes — bucket/key/region all populated | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Build is reproducible on this machine | `cd test && /usr/bin/make test; git status --porcelain` | exit 0, no generated-tree changes | ✓ PASS |
| Drift fires on a source edit without a rebuild | mutate bucket name → `make test` → `git add -A -- <3 pathspecs>; git diff --cached --exit-code` | exit 1, 8 files | ✓ PASS |
| Drift stays green on a current tree | same assertion, unmodified tree | exit 0 | ✓ PASS |
| FOUND-04 gate fires | `NEAR_BACKEND = LOCAL`; `protoconf compile . vprobe_gate04.mpconf` | exit 1, `_check_remote_backends` message | ✓ PASS |
| FOUND-05 gate fires | `FAR_BACKEND = MISMATCHED`; `protoconf compile . vprobe_gate05.mpconf` | exit 1, `_check_reads_are_produced` message | ✓ PASS |
| Unmutated control compiles | `protoconf compile . vprobe_gatectl.mpconf` | exit 0 | ✓ PASS |
| Gates are protected by a committed check | both calls → `pass`; `make test`; drift assertion | exit 0 and exit 0 | ✗ FAIL |
| SelectComponents reaches every matching component | diamond probe, mutate, re-select | 1 / one arm untouched / 2 | ✗ FAIL |
| `.github/workflows/drift.yaml` is well-formed | `yaml.safe_load` | 1 job, `contents: read`, 3 triggers | ✓ PASS |
| Generated workflow rename is caught | rename output key → `make test` → drift assertion | exit 1 (caught, via `test/outputs/`) — but see CR-03 | ⚠️ PARTIAL |
| First CI run of drift.yaml | — | cannot run GitHub Actions locally | ? SKIP → human |

### Probe Execution

| Probe | Command | Result | Status |
|-------|---------|--------|--------|
| `test/src/select_test.mpconf` | `cd test && /usr/bin/make test` | exit 0 — compiles, assertions hold *as written* | PASS (but see gap 1: assertions are name-only) |
| `test/src/handshake_test.mpconf` | `cd test && /usr/bin/make test` | exit 0 — ordering edge `{pub: [], sub: [pub]}` asserted live | PASS |
| FOUND-04 negative check | (declared in 01-03-PLAN, not committed) | no such file | MISSING_PROBE |
| FOUND-05 negative check | (declared in 01-03-PLAN, not committed) | no such file | MISSING_PROBE |

No `scripts/*/tests/probe-*.sh` convention exists in this repository; the project's probes are
`.mpconf` files that return `{}` and are compiled by `make test`. Both committed ones were run.

### Requirements Coverage

| Requirement | Source plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| FOUND-01 | 01-01 | CI fails when committed output differs from a fresh compile | ✓ SATISFIED | Truth 1. Two warnings on scope (CR-03, WR-07). |
| FOUND-02 | 01-02 | Component carries declared key/value labels | ✓ SATISFIED | `WithLabels` writes `Metadata.labels`; probe read the value back. No `Component.tags` added (D-07/D-08 held). |
| FOUND-03 | 01-02 | Select every component matching a predicate via exported `SelectComponents` | ✗ BLOCKED | Truth 2. Exported and callable, but does not return every matching component. |
| FOUND-04 | 01-03 | Compile fails naming the fix when an applied state has no remote backend | ✓ SATISFIED | Truth 3. Message register caveat (WR-10). Unprotected by any committed check (truth 5). |
| FOUND-05 | 01-03 | Cross-state handshake is visible to ordering derivation, or compile fails | ✓ SATISFIED | Truth 4. Positive half committed; negative half unprotected (truth 5). |

No orphaned requirements: `.planning/REQUIREMENTS.md` maps exactly FOUND-01..05 to Phase 1, and
all five are claimed across the three plans' `requirements:` frontmatter.

**REQUIREMENTS.md is ahead of the code.** All five are already marked `[x]` and `Complete` in
the traceability table. FOUND-03 is not.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | `TBD`/`FIXME`/`XXX` in phase-modified files | — | None found. Debt-marker gate passes. |
| — | — | `TODO`/`HACK`/`PLACEHOLDER` | — | None found in phase-modified files. |
| — | — | surviving `print(...)` in `.pinc`/`.mpconf` | — | None. Prohibition held. |
| `test/src/handshake_test.mpconf` | 41-64 | Dead constants (`MISMATCHED`, `LOCAL`) kept alive only by a comment describing a script that does not exist | ⚠️ Warning | Gap 2. A future reader who deletes them as dead code is correct on the evidence in the repository. |
| `test/src/handshake_test.mpconf` | 118-124 | Comment names the wrong gate: claims `LOCAL` is caught by `_producers`' duplicate-state `fail()` | ⚠️ Warning | Confirmed wrong — the traceback shows `_check_remote_backends` at line 204, and `_producers` is never reached. The comment exists to tell a maintainer where to look when a gate stops firing, and points at the wrong function. |
| `drivers/.../github_actions.pinc` | 199-224 | All three gate messages say "Pass `BACKEND` as the second argument to `WithState(...)`" | ⚠️ Warning | `BACKEND` is a local variable name in `test/src/core_test.mpconf:9`, not an API symbol, and `WithState` belongs to a driver this file's own header says it knows nothing about. Wrong advice for any caller who named their backend differently. |
| `test/protoconf.lock` | — | Committed with 6 `file:///Users/smintz/...` absolute paths | ⚠️ Warning | Every other contributor's `mod tidy` rewrites it, and CI must delete a committed integrity artefact to build. It is also in both `paths:` filters, so its churn triggers drift runs whose first action is to delete the file that triggered them. |
| `src/platform/core.pinc` | 204-209 | `walk_upstreams(component, next)` has the repo-wide hook signature but is a visitor — recursive return values are discarded | ℹ️ Info | Now module-level and reachable by anyone. A caller passing a transforming hook loses every upstream result silently. Renaming `next` to `visit` costs one word. |
| `src/platform/core.pinc` | 235-258 | `configs[prefix + "/" + key] = cfg` — a domain+name collision silently overwrites | ℹ️ Info | Pre-existing, not introduced here, but it defeats this phase's own job-id collision guard: that guard iterates `configs.keys()` and only ever sees one key. The phase added a loud check one layer above where the loss happens. |

### CR-03 re-tested: partially confirmed, partially refuted

The review claimed a renamed generated workflow makes the drift check "exit 0". Tested by
renaming the `.mpconf` output key to `.github/workflows/platform.yaml` and rebuilding:

- **Refuted for the uncommitted case.** The assertion exited **1**, because the rename also adds
  files under `test/outputs/` and `test/materialized_config/`, both of which *are* in the
  pathspec, and `git add -A` stages them.
- **Confirmed for the committed case, which is the one that matters.** `make workflows` copies
  and never deletes: after the rename build, `.github/workflows/` held `drift.yaml`,
  `platform.yaml` **and** the orphaned `terraform.yaml`, and `test/outputs/core_test/.github/workflows/`
  held both yamls too — protoconf does not prune either. Once that state is committed, a CI
  rebuild reproduces it exactly, the literal pathspec `.github/workflows/terraform.yaml` shows an
  empty diff, and the check goes green while the repository ships a live root workflow carrying
  `schedule: cron 0 3 * * *` and `terraform apply -auto-approve` against a state whose definition
  has moved.

This is a warning rather than a blocker: SC-1 as written ("a source edit without a local rebuild
can no longer pass CI green") is proven true, and the rename hole needs a deliberate rename to
open. Routed to human decision.

### Human Verification Required

#### 1. First CI run of the drift workflow

**Test:** Open a PR touching `test/src/**` and let `.github/workflows/drift.yaml` run.
**Expected:** protoconf 0.2.0-rc2 installs and passes its sha256 check, `cd test && make test`
succeeds, and the diff over the three asserted trees is empty on an already-current tree.
**Why human:** The workflow has never executed. Reproducibility was measured on darwin/arm64
with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64. A single byte of
disagreement turns every PR red, or silently accepts local output CI would have written
differently. 01-RESEARCH.md's assumption A1, still open, and unclosable from this machine.

#### 2. Accept or reject `SelectComponents`' value de-duplication

**Test:** Decide whether collapse-by-value is the intended contract given that Phase 5 SEC-01
("applies to every component matching a tag selector") and Phase 2 COST-01 ("propagates to every
component in that component's dependency subtree") both apply a hook across a selection.
**Expected:** Either gap 1 is closed before Phase 2 plans against it, or an `overrides:` entry
records the decision.
**Why human:** The code matches 01-02-PLAN's own must_have truth, so this is a specification
decision, not an execution slip. D-07's reversibility argument applies verbatim.

#### 3. Decide the scope of the drift assertion (CR-03 + WR-07)

**Test:** Decide whether `paths:` and the `git add` pathspec should widen from the literal
`.github/workflows/terraform.yaml` to `.github/workflows/**`, whether `test/Makefile` joins the
trigger list, and whether `make workflows` should prune what it no longer generates.
**Expected:** A decision recorded either way.
**Why human:** Reproducing it requires committing a rename, which this verification would not do.

### Gaps Summary

Three of the four roadmap success criteria are observably true in the code today, and each was
proven by execution rather than by reading. The drift check fires on the exact failure mode it
was written for. Both compile gates fire, at the right function, with the right message, in the
right order relative to the ordering derivation. Redis's state moved to S3 and the goldens agree.

Two things stop this phase from being finished, and they group under one theme: **the guarantees
are true but not held in place.**

The first is a correctness defect. `SelectComponents` is exported, reachable and wired, and it
returns an incomplete answer on the one graph shape it was written to handle. `Component` builds
each dependency factory once per parent, so a diamond is a tree with two distinct objects; the
value-keyed dict collapses them and the caller gets one. Mutating it leaves the other arm
untouched, and which arm survives is an ordering artifact. Every consumer planned for phases 2
and 5 applies a hook across a selection, which is exactly the operation this breaks. The phase
goal is "trustworthy enough to build four new stakeholder fan-outs on top of"; this is the
foundation for two of them, and it is cheap to change now and expensive after Phase 2.

The second is that the phase's headline guarantee has no committed defence. Deleting both gate
calls leaves `make test` at exit 0 and the drift check green — I ran it. The two constants the
fixture keeps alive for the negative checks currently guard nothing, and the comment forbidding
their deletion is the only thing standing between them and a reasonable cleanup commit. The plan
named "two scripted negative checks" as an acceptance criterion; the probe shipped, the scripts
did not. Everything the gates promise is one unnoticed edit away from being gone.

Neither gap is deferred to a later phase — nothing in phases 2-5 addresses either, and phases 2
and 5 consume the defective selector rather than repairing it.

---

_Verified: 2026-09-08T01:20:00Z_
_Verifier: Claude (gsd-verifier)_
