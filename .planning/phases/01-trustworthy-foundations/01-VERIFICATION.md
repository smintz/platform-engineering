---
phase: 01-trustworthy-foundations
verified: 2026-09-08T10:45:00Z
status: human_needed
score: 5/6 must-haves verified
covered_files:
  - ".github/workflows/drift.yaml"
  - ".planning/REQUIREMENTS.md"
  - ".planning/ROADMAP.md"
  - ".planning/phases/01-trustworthy-foundations/01-01-PLAN.md"
  - ".planning/phases/01-trustworthy-foundations/01-01-SUMMARY.md"
  - ".planning/phases/01-trustworthy-foundations/01-02-PLAN.md"
  - ".planning/phases/01-trustworthy-foundations/01-02-SUMMARY.md"
  - ".planning/phases/01-trustworthy-foundations/01-03-PLAN.md"
  - ".planning/phases/01-trustworthy-foundations/01-03-SUMMARY.md"
  - ".planning/phases/01-trustworthy-foundations/01-04-PLAN.md"
  - ".planning/phases/01-trustworthy-foundations/01-04-SUMMARY.md"
  - ".planning/phases/01-trustworthy-foundations/01-05-PLAN.md"
  - ".planning/phases/01-trustworthy-foundations/01-05-SUMMARY.md"
  - ".planning/phases/01-trustworthy-foundations/01-CONTEXT.md"
  - ".planning/phases/01-trustworthy-foundations/01-REVIEW.md"
  - "drivers/cicd/github_actions/src/github_actions.pinc"
  - "src/platform/core.pinc"
  - "src/platform/platform.pinc"
  - "test/Makefile"
  - "test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON"
  - "test/outputs/core_test/us-east-1/redis/infra/main.tf.json"
  - "test/src/core_test.mpconf"
  - "test/src/handshake_test.mpconf"
  - "test/src/select_test.mpconf"
covered_digest: "v1:sha256:27d9633e13e5f5434ccdb5152dea1bd635d0ba1b22818dd2765acf0031051ce6"
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 3/5
  gaps_closed:
    - "A platform author can write a predicate over Component.Metadata.labels and call the exported SelectComponents to retrieve every component in a dependency graph matching it (SC-2, FOUND-03) — closed by 01-05. Re-measured by an independent probe on a top -> {mid1, mid2} -> leaf diamond: every=['leaf','base','mid1','leaf','mid2','top'], pass1_count=2, mutation read back through an independent walk = ['VPROBE-STAMP','VPROBE-STAMP'], pass2=['leaf','leaf'], empty=[], single=['base']."
    - "Both compile gates are proven to FIRE by a committed defence (01-03-PLAN must_have, protecting SC-3/SC-4) — closed by 01-04. Re-measured by re-running the exact falsification that defined the gap: both gate calls replaced by `pass`, mutation grep-confirmed, `cd test && make test` now exits 2 with `gates: FOUND-04 gate did not fire`. Prior measurement on the same mutation was exit 0."
  gaps_remaining: []
  regressions: []
  note: "01-02-PLAN's de-dup must_have and D-11's de-duplication clause were superseded by a human decision at 01-05's blocking checkpoint (option `every-occurrence`). Verified against the new contract, not the superseded one — not reported as a regression. D-11's prohibition on a `\"<domain>/<name>\"` uniqueness key was NOT superseded and is confirmed still honoured: no such key exists in src/platform/core.pinc and no de-duplicating helper is exported."
deferred: []
advisory: []
human_verification:
  - test: "Open a pull request that touches test/src/** and let .github/workflows/drift.yaml run on GitHub for the first time."
    expected: "The workflow installs protoconf 0.2.0-rc2 (sha256 verified), runs `cd test && make test` — which now also runs `make gates` — and the diff over the three asserted trees is empty on an already-current tree."
    why_human: "The workflow has still never executed: `gh run list --workflow drift.yaml` returns HTTP 404 (`not found on the default branch`). Golden-file byte-reproducibility was measured only on darwin/arm64 with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64. This is assumption A1 in 01-RESEARCH.md, still open, and unclosable from this machine. It now also carries `make gates`, which shells out to `sed`/`grep`/`mktemp` on a runner this repository has never exercised."
  - test: "Decide whether `GetConfigs`' silent config overwrite is acceptable before Phase 2 plans COST-02 against it (CR-01 in 01-REVIEW.md)."
    expected: "Either `collect_configs` refuses to overwrite a differing config at the same `\"<domain>/<name>/<config key>\"` (the `_producers` duplicate-state idiom the repo already has), or a decision is recorded accepting the collapse."
    why_human: "Specification-level decision, not an execution slip, and outside every Phase 1 success criterion. Measured on this checkout: a diamond whose leaf carries a `WithState` config gives `leaf_occurrences=2 selected=2 config_keys=[\"leaf/infra/main.tf.json\"]` — `SelectComponents` now correctly hands the caller both live objects and `GetConfigs` then renders one. Confirmed strictly pre-existing: `configs[prefix + \"/\" + key] = cfg` is byte-identical at the `init` commit (ba9c1aa:src/platform/core.pinc:203), so this phase neither introduced it nor changed `GetConfigs`' behaviour. It matters because Phase 2 COST-02 ('every Terraform resource emitted by every driver carries the cost-attribution tags') and Phase 5 SEC-01/SEC-03 all write through a selection into configs."
  - test: "Run `make gates` twice concurrently in one worktree on a machine that is not this one, or add a held-out check for the collision."
    expected: "Per 01-04-PLAN's backstop truth: the collision on the two fixed probe filenames surfaces as a compile error naming a missing or half-written probe, never as a green run that skipped a gate."
    why_human: "Tagged `verification: backstop` by the plan itself and covered by no committed check. Directly observed here 6/6 concurrent pairs: both runs exit 0 and both print `gates: both compile gates fired`, no probe residue, `src/handshake_test.mpconf` sha unchanged. The safety half of the claim held in every trial and holds structurally (each run greps its own `mktemp` log, so green implies the message was seen). The stated MECHANISM was never reproduced — the collision is benign, because both runs write byte-identical probe content derived from the same committed fixture. The truth as written is therefore not confirmed, and there is no held-out test to confirm it."
  - test: "Decide the scope of the drift assertion (CR-03 + WR-07 from the prior verification — still open, untouched by 01-04/01-05)."
    expected: "Either `paths:` and the `git add` pathspec widen from the literal `.github/workflows/terraform.yaml` to `.github/workflows/**`, `test/Makefile` joins the trigger list, and `make workflows` prunes what it no longer generates — or the risk is accepted and recorded."
    why_human: "Reproducing it requires committing a rename, which this verification would not do. Re-confirmed unchanged: `test/Makefile`'s `workflows` target is still `mkdir -p` + `cp` with no prune, and `drift.yaml` still filters on the literal filename, which is `TerraformPipeline`'s overridable `name` default. The consequence is a live root workflow carrying `terraform apply -auto-approve` behind a daily cron surviving a rename of the definition that produced it."
---

# Phase 1: Trustworthy Foundations Verification Report

**Phase Goal:** The platform's own build and cross-state wiring are trustworthy enough to build four new stakeholder fan-outs on top of
**Verified:** 2026-09-08T10:45:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure (01-04, 01-05). Replaces the `gaps_found` / 3-of-5 report of 2026-09-08T01:20:00Z.

## Method and repository state

Every finding below was produced by executing code in this checkout. No claim in any
SUMMARY.md was accepted as evidence; each of the two closed gaps was re-tested by re-running
the exact falsification that defined it, and both gap-closure fixtures were themselves
falsified to prove they are not vacuous. Every mutation was confirmed to have landed — by
`grep` or `sed -n` on the mutated file — before the resulting compile was interpreted.

**The repository is byte-identical to how I found it.** Evidence:

```
start:  git status --porcelain  ->  M .planning/config.json / M .planning/state.json / ?? .gsd/ / ?? .planning/milestone.lock
end:    git status --porcelain  ->  M .planning/config.json / M .planning/state.json / ?? .gsd/ / ?? .planning/milestone.lock
git diff --stat  ->  .planning/config.json | 2 +-,  .planning/state.json | 8 ++++----   (both pre-existing)

sha256 before == after:
  1ed03aa5…  src/platform/core.pinc
  8b38efc2…  drivers/cicd/github_actions/src/github_actions.pinc
  19a82ef1…  test/src/handshake_test.mpconf
  7592711b…  test/src/core_test.mpconf
```

Every scratch probe (`vprobe_select.mpconf`, `vprobe_getconfigs.mpconf`, `vprobe_stamp.mpconf`)
was removed; `ls test/src/` ends at the four committed entries. No `gate0*_probe.mpconf`
residue survived any run, including four interrupted ones.

## MVP-mode note (unchanged, still needs a decision)

`.planning/ROADMAP.md:38` still declares `**Mode:** mvp` while the phase goal is not a User
Story — `query user-story.validate` returns `valid: false` with all four slot errors. As in
the prior report, this verification uses the four concrete ROADMAP Success Criteria rather
than refusing outright, and omits the User Flow Coverage section, which would have been
invention. Run `/gsd mvp-phase 1` or drop the `Mode: mvp` line.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | CI fails the build when a fresh compile differs from what's committed — a source edit without a local rebuild can no longer pass CI green (SC-1, FOUND-01) | ✓ VERIFIED | Regression re-run. Control on a clean tree: `git add -A -- <3 pathspecs>; git diff --cached --exit-code` → exit **0**. Then edited `test/src/core_test.mpconf:10` (bucket → `vprobe-drift-bucket`, grep-confirmed), ran drift.yaml's own sequence (`cd test && make test` then the assertion) → exit **1**, 8 files staged across `test/outputs/` and `test/materialized_config/`. Restored and rebuilt → tree clean. Warnings below (CR-03/WR-07 scope, still open). |
| 2 | A platform author can write a predicate over `Component.Metadata.labels` and call the exported `SelectComponents` to retrieve **every** component in a dependency graph matching it (SC-2, FOUND-02/03) | ✓ VERIFIED | **Gap 1 closed.** Independent probe (mine, not the committed fixture) on a `top -> {mid1, mid2} -> leaf` diamond: `every=["leaf","base","mid1","leaf","mid2","top"] pass1_count=2 readback=["VPROBE-STAMP","VPROBE-STAMP"] pass2=["leaf","leaf"] empty=[] single=["base"]`. Both diamond occurrences returned; a mutation through the selection reached BOTH embedded objects (read back by a walk that does not use `SelectComponents`); re-selecting after the mutation returned the same 2 (previously 1 then 2). The order matches the corrected `['leaf','base','mid1','leaf','mid2','top']`, not the wrong list the prior report proposed. |
| 3 | Compiling a component whose state CI will apply, but that has no remote backend configured, fails with a message naming the missing backend — no silent fallback to local state (SC-3, FOUND-04) | ✓ VERIFIED | Now proven by a committed command rather than an ad-hoc probe. `cd test && make gates` on the clean tree prints `gates: both compile gates fired` and exits 0. Deleting only this gate (line 670 → `pass`, grep-confirmed `remote_backends=0 reads=1`) → `make gates` exit **2**, `gates: FOUND-04 gate did not fire — _check_remote_backends did not report a local backend`. |
| 4 | Compiling a cross-state handshake CI's ordering derivation cannot see fails with a message naming the fix, rather than producing a wrong or partial apply order (SC-4, FOUND-05) | ✓ VERIFIED | Deleting only this gate (line 671 → `pass`, grep-confirmed `remote_backends=1 reads=0`) → `make gates` exit **2**, `gates: FOUND-05 gate did not fire — _check_reads_are_produced did not report a read of an unproduced state`. The positive half (`sub -> [pub]`) is still asserted live inside `make test`. |
| 5 | Both compile gates are proven to FIRE, not merely to exist, by a committed defence that `make test` runs (01-03-PLAN must_have; 01-04-PLAN gap-closure must_have) | ✓ VERIFIED | **Gap 2 closed.** The prior report's exact falsification, re-run: both gate calls replaced by `pass` (grep confirms only the two `def` lines and two comments remain — zero call sites), then `cd test && /usr/bin/make test` → exit **2** with `gates: FOUND-04 gate did not fire`. Prior measurement on this identical mutation was exit 0. The design point is confirmed by the same log: the mutated compile still exits non-zero from `_producers`' duplicate-state `fail()` at `github_actions.pinc:125` — so an exit-code assertion would have called a deleted gate "firing", and the message+traceback assertion is what caught it. |
| 6 | FOUND-04/FOUND-05 concurrency edge: two concurrent `make gates` runs collide on the two fixed probe filenames and the collision surfaces as a compile error naming a missing or half-written probe — never as a green run that skipped a gate (01-04-PLAN, `verification: backstop`) | ⚠️ insufficient_spec (abstained) | Directly observed 6/6 concurrent pairs: **both** runs exit 0, both print `gates: both compile gates fired`, no probe residue, `src/handshake_test.mpconf` sha unchanged. The safety half ("never a green run that skipped a gate") held in every trial and holds structurally — each run greps its own `mktemp` log, so a green result implies its own compile emitted the gate message. The stated **mechanism** was never reproduced: the collision is benign, because both runs write byte-identical probe content from the same committed fixture. No held-out or property-based check exists. Abstained rather than marked VERIFIED, because certifying a statement whose mechanism measurement contradicts would be dishonest. Routed to human. |

**Score:** 5/6 truths verified (0 present-but-behavior-unverified; 1 abstained, `insufficient_spec`)

### Deferred Items

None. Nothing in Phases 2-5 addresses any open item from this phase; Phases 2 and 5 consume
these foundations rather than repair them.

### Advisory (New Scope, Unevidenced)

New-scope Step 7 findings with no deterministic evidence — reported, not blocking.

| # | Finding | Category | Why Advisory |
|---|---------|----------|--------------|
| — | None | — | No Step 7 finding was classified as a 🛑 Blocker on this pass. CR-01 is the only candidate; it sits on `src/platform/core.pinc`, modified since the prior `verified:` timestamp, so the evidence gate would not have downgraded it. It is classified ⚠️ Warning on its merits (see Anti-Patterns and Human Verification #2), not downgraded by this gate. |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `test/Makefile` — `gates` target | Substitutes `LOCAL`/`MISMATCHED` into throwaway copies, confirms each landed, asserts on the gate's own MESSAGE + traceback frame, invoked from `test` | ✓ VERIFIED | Exists, 60 lines, `.PHONY: test workflows gates`, `test` ends with `$(MAKE) gates`. `make test` output ends `make gates` → `gates: both compile gates fired`. Wired into CI with no workflow edit: `drift.yaml:60-61` already runs `cd test && make test`. |
| `test/Makefile` — landing check | Distinguishes "gate did not fire" from "mutation never written" | ✓ VERIFIED | Falsified directly: appended a trailing comment to the `NEAR_BACKEND = BACKEND` anchor, breaking the `sed` anchor. Result: exit 2, `gates: FOUND-04 substitution did not land in src/gate04_probe.mpconf` — the substitution-failure branch, not the dead-gate branch. See WR-01 for the stale line number in that message. |
| `test/Makefile` — cleanup trap | `trap ... EXIT` removes both probe copies; tracked fixture never mutated in place | ✓ VERIFIED | Interrupted mid-run at four delays (0.05s / 0.12s / 0.20s / 0.30s against a 0.38s runtime): every run `rc=143`, `leftover_probes=0`, `fixture_sha=19a82ef1` unchanged. `git ls-files \| grep gate0.*probe` → empty: no probe copy is committed. |
| `test/Makefile` — non-skippable | No `-` recipe prefix, no `\|\| true` on an assertion, no SKIP_GATES, no continue-on-error | ✓ VERIFIED | The only two `\|\| true` occurrences (lines 42, 53) sit on the `protoconf compile` invocations — which are EXPECTED to fail — never on a `grep` assertion. `drift.yaml` has no `continue-on-error`. |
| `src/platform/core.pinc` — `SelectComponents` | Returns every occurrence in post-order; no de-dup key | ✓ VERIFIED | Lines 232-240: `found = []` / `found.append(c)` / `return found`. No value-keyed dict, no `"<domain>/<name>"` key (D-11's surviving prohibition). Returns live references, not copies — proven by the stamp read-back. |
| `src/platform/core.pinc` — `walk_upstreams` | Module-level, one traversal, two consumers, honest parameter name | ✓ VERIFIED | Line 208 `def walk_upstreams(component, visit):` — the `next` → `visit` rename landed. Consumers: `SelectComponents:239` and `GetConfigs:265`. |
| `src/platform/core.pinc` — `WithLabels` | Writes `Component.Metadata.labels`, constructs `Metadata` first | ✓ VERIFIED | Lines 134-144, nil-guard present. My probe read `tier` back out of a freshly-built graph. |
| `src/platform/platform.pinc` | Exports `SelectComponents` and `WithLabels` through the facade (D-13) | ✓ VERIFIED | Both in the `load(...)` list (lines 10, 16) and the `platform` struct (lines 59, 67). |
| `test/src/select_test.mpconf` | Committed assertions: order, adjacency, empty, single-element, idempotency, mutation reachability read back independently | ✓ VERIFIED | 153 lines, compiles inside `make test`, materializes nothing. **Falsified to prove non-vacuity** — see Test Quality Audit. No `len(` anywhere (01-05's own prohibition against a softened count assertion). |
| `test/src/handshake_test.mpconf` | Two anchored switch points + prose naming the committed command and the right gate | ✓ VERIFIED | `MISMATCHED`/`LOCAL` are now inputs to `make gates`, not comment-protected dead constants. Prose at :42-48 names `make gates`; the comment at :128-136 now names `_check_remote_backends (github_actions.pinc:204)` and `_check_reads_are_produced (:239)` — both cited lines confirmed to hold the corresponding `fail(`. The prior report's "comment names the wrong gate" warning is resolved. |
| `.github/workflows/drift.yaml` | Hand-written, source-path triggered, `contents: read`, sha-pinned compiler | ✓ VERIFIED | Unchanged by gap closure and re-checked: `permissions: contents: read` (:26), `PROTOCONF_VERSION: 0.2.0-rc2` + `PROTOCONF_SHA256` with `sha256sum -c -` (:32-45), no `pull_request_target`, no `id-token`, no `pull-requests` permission, no terraform install. |
| root `outputs/` and `materialized_config/` | Deleted (D-05) | ✓ VERIFIED | Both absent; `git ls-files` finds no root-level generated tree. Exactly one, under `test/`. |
| `drivers/.../github_actions.pinc` gates | `_check_remote_backends` (3 branches) and `_check_reads_are_produced`, called before `dependencies` | ✓ VERIFIED | Lines 193-224 and 230-245; call order 670 → 671 → 673 confirmed by source and by both tracebacks. Both proven to fire, and now proven to be missed if deleted. |
| `test/outputs/.../redis/infra/main.tf.json` + `.materialized_JSON` | S3 backend, not local (D-15/D-16) | ✓ VERIFIED | A clean `make test` reproduces both byte-for-byte (`git status` clean). |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `test/Makefile` `test` | `test/Makefile` `gates` | `$(MAKE) gates` | ✓ WIRED | Observed in `make test` output. This is the link that did not exist at the prior verification. |
| `test/Makefile` `gates` | the two `fail()` messages in `github_actions.pinc` | `protoconf compile . gate0N_probe.mpconf` + `grep` on message AND function name | ✓ WIRED | Both directions proven: green when the gates exist, red-with-the-right-message when either is deleted. |
| `.github/workflows/drift.yaml` | `make gates` | `cd test && make test` (workflow NOT edited) | ✓ WIRED | `drift.yaml:60-61` unchanged; coverage arrives through the target it already invokes. Confirmed by the both-gates-deleted run: `make test` exit 2, which is what the workflow's `rebuild` step would surface. |
| `SelectComponents` result | caller's mutation of a matched component | returned object identity (live reference) | ✓ WIRED | **Was NOT_WIRED.** Independent probe: stamping every returned `tier=cache` component and reading back through a private walk yields `["VPROBE-STAMP","VPROBE-STAMP"]` — both arms of the diamond reached. |
| `select_test.mpconf` `occurrences(...)` | `component.upstreams.components` | direct walk, NOT `SelectComponents` | ✓ WIRED | Lines 97-102. The observer is independent of the observed, so the fixture cannot pass by the selector omitting an object in both directions. |
| `GetConfigs` / `SelectComponents` | `walk_upstreams` | one shared module-level function | ✓ WIRED | One traversal, two consumers (D-10). `GetConfigs` output unchanged: full rebuild leaves the tree clean (D-12). |
| `TerraformPipeline` | `_check_remote_backends` → `_check_reads_are_produced` → `dependencies` | call order 670, 671, 673 | ✓ WIRED | Confirmed by source and by both tracebacks. |
| `test/Makefile` `test` | `.github/workflows/terraform.yaml` | `make workflows` → `cp` | ⚠️ PARTIAL | Unchanged and still un-pruning: the target is `mkdir -p` + `cp` with no delete. CR-03 remains open — routed to human. |
| `drift.yaml` `paths:` | source trees + literal `.github/workflows/terraform.yaml` | trigger filter | ⚠️ PARTIAL | Still the literal filename (an overridable `TerraformPipeline` default) and still omits `test/Makefile` — the file that now decides whether the gates run at all. WR-07 widened by 01-04: an edit to `test/Makefile` that neuters `gates` matches no drift trigger. |
| `SelectComponents` result | `GetConfigs` rendered output | `configs[prefix + "/" + key]` | ✗ COLLAPSES | Both live objects are now delivered to the caller; `GetConfigs` renders one. Measured: `leaf_occurrences=2 selected=2 config_keys=["leaf/infra/main.tf.json"]`. Pre-existing and byte-identical at `init` — see CR-01 assessment. |

### Data-Flow Trace (Level 4)

| Artifact | Data variable | Source | Produces real data | Status |
|----------|--------------|--------|--------------------|--------|
| `SelectComponents` | `found` (list) | `walk_upstreams` visitor, appended per occurrence | Yes — every occurrence, live references, order stable, mutation-independent | ✓ FLOWING |
| `WithLabels` | `component.metadata.labels` | call-site kwargs | Yes — probe read `tier="cache"` back out | ✓ FLOWING |
| `make gates` verdict | the two `grep -q` results | the mutated probe's own compiler log (`mktemp`, per run) | Yes — verdict derives from the compiler's output, not from an exit code or a SUMMARY claim | ✓ FLOWING |
| `dependencies(configs)` | `deps[key]` | `_producers` ∩ `_reads` | Yes — `{pub: [], sub: [pub]}` asserted live in `make test` | ✓ FLOWING |
| redis `main.tf.json` | `terraform.backend.s3` | `WithState(..., BACKEND)` → `key_for` | Yes | ✓ FLOWING |
| `GetConfigs` | `configs[prefix + "/" + key]` | `walk_upstreams` over every occurrence | Partially — real configs, but one silently overwrites another at the same key | ⚠️ HOLLOW (pre-existing, see CR-01) |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Clean tree builds green and runs the gates | `cd test && /usr/bin/make test` | exit **0**, output ends `make gates` → `gates: both compile gates fired`; `git status --porcelain` unchanged | ✓ PASS |
| Deleting BOTH gate calls now fails the build (gap-2 falsification) | lines 670-671 → `pass` (grep: 0 call sites), `cd test && make test` | exit **2**, `gates: FOUND-04 gate did not fire` — prior measurement on this mutation was exit **0** | ✓ PASS |
| The verdict is message-based, not exit-code-based | same run, log inspection | mutated compile ALSO exits non-zero from `_producers:125` duplicate-state `fail()`; the gates target still called it a dead gate | ✓ PASS |
| Deleting ONLY the FOUND-04 gate is caught | line 670 → `pass` (grep: `remote_backends=0 reads=1`), `make gates` | exit **2**, `gates: FOUND-04 gate did not fire` | ✓ PASS |
| Deleting ONLY the FOUND-05 gate is caught | line 671 → `pass` (grep: `remote_backends=1 reads=0`), `make gates` | exit **2**, `gates: FOUND-05 gate did not fire` | ✓ PASS |
| A broken anchor is reported as a non-landing, not a dead gate | trailing comment on the `NEAR_BACKEND` anchor, `make gates` | exit **2**, `gates: FOUND-04 substitution did not land …` | ✓ PASS |
| `make gates` is idempotent and leaves no residue | run twice; compare `git status` md5 and fixture sha | `state1 == state2` (`fd33495f…`), fixture sha `19a82ef1…` unchanged, `ls src/` = 4 committed entries | ✓ PASS |
| Interrupting `make gates` leaves the tracked fixture intact | SIGINT+SIGTERM at 0.05/0.12/0.20/0.30s (runtime 0.38s) | 4/4: `rc=143`, `leftover_probes=0`, fixture sha unchanged | ✓ PASS |
| `SelectComponents` returns every occurrence, reaches both arms, is idempotent | independent `vprobe_select.mpconf` | `every=["leaf","base","mid1","leaf","mid2","top"] pass1=2 readback=["VPROBE-STAMP","VPROBE-STAMP"] pass2=["leaf","leaf"] empty=[] single=["base"]` | ✓ PASS |
| Drift fires on a source edit after the rebuild CI performs | edit `core_test.mpconf:10`, `make test`, staged diff over 3 pathspecs | exit **1**, 8 files | ✓ PASS |
| Drift stays green on a current tree | same assertion, unmodified tree | exit **0** | ✓ PASS |
| `GetConfigs` collapses two diamond occurrences | independent `vprobe_getconfigs.mpconf` | `leaf_occurrences=2 selected=2 config_keys=["leaf/infra/main.tf.json"]` | ✗ FAIL (pre-existing, CR-01 — not a Phase 1 criterion) |
| Concurrent `make gates` never goes green having skipped a gate | 6 concurrent pairs | 6/6 both exit 0, both print `both compile gates fired`, no residue | ✓ PASS (mechanism unconfirmed — see truth 6) |
| First CI run of `drift.yaml` | `gh run list --workflow drift.yaml` | HTTP 404 — not found on the default branch; never executed | ? SKIP → human |

### Probe Execution

| Probe | Command | Result | Status |
|-------|---------|--------|--------|
| `test/src/select_test.mpconf` | `cd test && /usr/bin/make test` | exit 0 — compiles, all six assertions hold | PASS |
| `test/src/handshake_test.mpconf` | `cd test && /usr/bin/make test` | exit 0 — ordering edge `{pub: [], sub: [pub]}` asserted live | PASS |
| FOUND-04 negative check | `cd test && /usr/bin/make gates` (was MISSING_PROBE) | `gates: both compile gates fired`, exit 0; red with the right message under three separate mutations | PASS |
| FOUND-05 negative check | `cd test && /usr/bin/make gates` (was MISSING_PROBE) | same target, second half | PASS |

Both probes the prior report recorded as MISSING_PROBE now exist as a single committed
`make gates` target invoked from `make test`. No `scripts/*/tests/probe-*.sh` convention
exists in this repository; the project's probes are `.mpconf` files that return `{}` plus
this Make target, and all were run.

### Test Quality Audit

| Check | Result |
|-------|--------|
| Disabled/skipped tests on requirements | None — the project has no skip mechanism; assertions are Starlark `fail()` calls that run on every compile. |
| Circular tests (expected values generated by the system under test) | None. `select_test.mpconf`'s expected order and stamp values are literals, and the read-back observer (`occurrences`) is written in the fixture, not borrowed from `src/platform/core.pinc`. `make gates`' expected values are literal substrings of the driver's `fail()` messages. |
| Assertion strength | Value-level and behavioural throughout: exact list equality on names, exact list equality on stamped descriptions, and message+traceback-frame matching for the gates. No existence-only or type-only assertions on any requirement. |
| **Non-vacuity, `select_test.mpconf`** | **Falsified.** Reverted `SelectComponents` to the pre-01-05 value-keyed dict (`found = {}` / `found[c] = True` / `return found.keys()`, mutation confirmed by `sed -n`): `cd test && make test` → exit **2**, `SelectComponents: expected every occurrence in post-order … got [` . Then isolated the mutation assertion (deleted the earlier name assertions into a scratch copy) against the same reverted implementation: it fires independently with `expected the stamp to reach both leaf occurrences, got [`. Both assertions catch the exact original defect. |
| **Non-vacuity, `make gates`** | **Falsified three ways** (both gates deleted, each gate deleted alone) plus the anchor-break case. Each produced the correct, distinct diagnostic. |
| Coverage quantity | 01-05 named 6 committed assertions (order, tier=app, adjacency, empty, single-element, mutation reachability, idempotency); 7 are present and active in `select_test.mpconf`. |

**Disabled tests on requirements:** 0. **Circular patterns:** 0. **Insufficient assertions:** 0.

### Decision Coverage

`query check.decision-coverage-verify` → `{ skipped: false, blocking: false, total: 18,
honored: 18, not_honored: [] }` — all trackable `01-CONTEXT.md` decisions (D-01..D-18) appear
in shipped artifacts. Non-blocking gate; recorded for drift tracking.

Two decisions were deliberately superseded and the supersession is documented rather than
silent: **D-11's de-duplication clause** and **01-02-PLAN's de-dup must_have**, both reversed
by the human's `every-occurrence` selection at 01-05's blocking `checkpoint:decision` and
tabulated in `01-05-SUMMARY.md:152-170`. **D-11's prohibition on a `"<domain>/<name>"` key was
NOT superseded**, and is verified still honoured: no such key exists in
`src/platform/core.pinc` and no de-duplicating helper is exported from `platform.pinc`.
Verified against the new contract, per that decision — not reported as a regression.

### Prohibitions

All prohibitions in this phase are judgment-tier (`verification: null` or unadorned list
items). This is an autonomous verification run, so the verdicts below are a
**NON-AUTHORITATIVE LLM-judge assessment** — `unverified-prohibition, human review
recommended`. None was silently passed; none halts the run.

| Plan | Prohibition (abbreviated) | Judge verdict | Basis |
|------|---------------------------|---------------|-------|
| 01-01 | Drift workflow never emitted by the driver (D-01) | HELD | `drift.yaml` is absent from every driver output; the driver's only `drift` references are its own job label and `drift_cron`. |
| 01-01 | No fork-context PR trigger, no OIDC, no PR-write permission, no terraform install | HELD | `grep` for `pull_request_target` / `id-token` / `pull-requests` / terraform setup in `drift.yaml` → none. `permissions: contents: read`. |
| 01-01 | `terraform.yaml` never hand-edited; `protoconf.lock` never in the assertion | HELD | `terraform.yaml` reproduces byte-identically from `make test`; the lock is in `paths:` only, not in the `git add` pathspec. |
| 01-01 | Root `Makefile` and `providers.tf` untouched (D-06) | HELD | `providers.tf` last changed in `f42501d`, which `git merge-base --is-ancestor` confirms precedes the first Phase 1 implementation commit. Root `Makefile` unchanged. |
| 01-02 | No second traversal (D-10) | HELD | One `walk_upstreams`, two consumers. |
| 01-02 | No `Component.tags` field; schema not edited (D-07) | HELD | `git diff ba9c1aa HEAD -- src/platform/v1/platform.proto` → empty. No planning artifact names `Component.tags`. |
| 01-02 | `Metadata.tags` stays unwritten and unread (D-08) | HELD | Only reference repo-wide is a prose comment explaining why it is not used. |
| 01-02 | `GetConfigs`' observable output unchanged (D-12) | HELD | Full rebuild leaves `test/outputs/` and `test/materialized_config/` byte-identical. |
| 01-02 | `WithLabels` is an ordinary `component_filter`, not `Inherit` (D-09) | HELD | `return component_filter(do)`. |
| 01-02 | `SelectComponents` does not de-duplicate by a `"<domain>/<name>"` key | HELD | No key of any kind; a plain list. Explicitly re-affirmed by the human decision. |
| 01-02 / 01-03 | No surviving `print(...)` in any `.pinc`/`.mpconf` | HELD | Repo-wide grep → none. |
| 01-03 | Neither check is a `.proto-validator` or `buf.validate` annotation (D-14) | HELD | Zero `.proto-validator` files tracked; both checks are `fail()` in the driver. |
| 01-03 | `terraform.pinc` not edited | HELD | Absent from every Phase 1 implementation commit. |
| 01-03 | `dependencies(configs)` signature unchanged, still in `actions` | HELD | `def dependencies(configs):` at :142, exported at :754. |
| 01-04 | The gates target must not become skippable | HELD | No `-` prefix, no `\|\| true` on an assertion (only on the two compiles that are expected to fail), no SKIP_GATES, no `continue-on-error`. |
| 01-04 | A gate assertion must never be weakened to a generic substring | HELD (empirically) | The both-gates-deleted run exits non-zero from the duplicate-state `fail()`, and the assertions still reported the gates dead — proving the substrings do not match that unrelated failure. |
| 01-04 | A probe copy must never be committed | HELD | `git ls-files \| grep gate0.*probe` → empty; trap-verified clean across 4 interrupted runs. |
| 01-05 | `SelectComponents` must never return copies | HELD (empirically) | Stamp through the selection read back by an independent walk on both arms. |
| 01-05 | De-duplication must not return under a different name | HELD | No dedup helper exported; `platform.pinc` gained only `SelectComponents` and `WithLabels`. |
| 01-05 | The mutation assertion must not be softened to a count or name list | HELD | `select_test.mpconf` contains no `len(`; the assertion compares stamped `description` values. |

### Requirements Coverage

| Requirement | Source plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| FOUND-01 | 01-01 | CI fails when committed output differs from a fresh compile | ✓ SATISFIED | Truth 1. Two open scope decisions (CR-03, WR-07) routed to human, neither falsifying SC-1. |
| FOUND-02 | 01-02 | Component carries declared key/value labels | ✓ SATISFIED | `WithLabels` writes `Metadata.labels`; independent probe read the value back on a freshly-built graph. |
| FOUND-03 | 01-02, 01-05 | Select every component matching a predicate via exported `SelectComponents` | ✓ SATISFIED | Truth 2. Was BLOCKED; closed by 01-05 and re-measured independently. |
| FOUND-04 | 01-03, 01-04 | Compile fails naming the fix when an applied state has no remote backend | ✓ SATISFIED | Truths 3 and 5. Gate fires, and its deletion is now caught by a committed command CI already runs. |
| FOUND-05 | 01-03, 01-04 | Cross-state handshake visible to ordering derivation, or compile fails | ✓ SATISFIED | Truths 4 and 5. |

No orphaned requirements: `.planning/REQUIREMENTS.md` maps exactly FOUND-01..05 to Phase 1, and
all five are claimed across the five plans' `requirements:` frontmatter (01-01: FOUND-01;
01-02: FOUND-02, FOUND-03; 01-03: FOUND-04, FOUND-05; 01-04: FOUND-04, FOUND-05; 01-05:
FOUND-03).

**REQUIREMENTS.md bookkeeping is inconsistent and currently backwards** (WR-02 below).

### Anti-Patterns Found

Files scanned: every file touched by the ten Phase 1 implementation commits.

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | `TBD`/`FIXME`/`XXX` in phase-modified files | — | **None found. Debt-marker gate passes.** |
| — | — | `TODO`/`HACK`/`PLACEHOLDER` | — | None found in phase-modified files. |
| — | — | surviving `print(...)` in `.pinc`/`.mpconf` | — | None. |
| `src/platform/core.pinc` | 265 | **CR-01** — `configs[prefix + "/" + key] = cfg` silently overwrites when two components share `"<domain>/<name>"` | ⚠️ Warning | Measured: `leaf_occurrences=2 selected=2 config_keys=["leaf/infra/main.tf.json"]`. Known and already reported (`01-REVIEW.md` CR-01; flagged as pre-existing in the prior verification's own table). **Strictly pre-existing:** byte-identical at `ba9c1aa:src/platform/core.pinc:203`, and `GetConfigs` never consumed `SelectComponents`, so the `every-occurrence` change did not alter its behaviour — the goldens are unchanged (D-12 holds). Not a blocker: it falsifies no Phase 1 success criterion and no FOUND requirement. It IS a live risk to Phase 2 COST-02 and Phase 5 SEC-01/SEC-03, which all write through a selection into configs — routed to human decision #2. |
| `test/Makefile` | 38, 49 | **WR-01** — the substitution-failure messages cite `test/src/handshake_test.mpconf:64` and `:70`; the anchors are actually at **:73** and **:79** | ⚠️ Warning | Confirmed by triggering the branch: the message a contributor sees points at `"us-east-1",` (a line inside the `BACKEND` constructor) and at `LOCAL = LocalBackend()`. 01-04's own prose added the lines that shifted them. The diagnostic exists precisely to be followed when the check goes red; it currently misdirects. One-line fix. |
| `.planning/REQUIREMENTS.md` | traceability + checkboxes | **WR-02** — status rows are inverted relative to what was ever measured | ⚠️ Warning | FOUND-01 and FOUND-02 read `[ ]` / `Gaps Found` though both were VERIFIED at the prior pass and are VERIFIED again here; FOUND-03 reads `[x]` / `Complete` though it was the phase's one BLOCKED requirement at the time that status was written. Commit `48ff549` ("revert premature Complete requirements after gaps found") reverted the wrong two rows. Correct end state after this report: all five Complete. |
| `.github/workflows/drift.yaml` + `test/Makefile` | `paths:` / `workflows` | **CR-03 / WR-07** — literal `.github/workflows/terraform.yaml` pathspec, no prune in `make workflows`, `test/Makefile` absent from the trigger list | ⚠️ Warning | Carried forward unchanged; 01-04 widened it — an edit to `test/Makefile` that neuters `gates` matches no drift trigger. Routed to human decision #4. |
| `drivers/.../github_actions.pinc` | 201, 207, 222 | All three gate messages advise "Pass `BACKEND` as the second argument to `WithState(...)`" | ⚠️ Warning | Carried forward. `BACKEND` is a local variable name in `test/src/core_test.mpconf:9`, not an API symbol, and `WithState` belongs to a driver this file's header says it knows nothing about. Wrong advice for a caller who named their backend differently. Note the assertions in `make gates` do **not** key on this substring, so fixing the wording is safe. |
| `test/protoconf.lock` | — | 6 `file:///Users/smintz/...` absolute paths committed | ⚠️ Warning | Carried forward. CI must delete a committed integrity artefact to build, and the lock's churn triggers drift runs whose first action is to delete the file that triggered them. |

**Resolved since the prior verification:** the two dead constants in `handshake_test.mpconf`
(now inputs to `make gates`), the comment naming the wrong gate function (now names
`_check_remote_backends:204` / `_check_reads_are_produced:239`, both confirmed), and
`walk_upstreams`' misleading `next` parameter (renamed `visit`).

### Human Verification Required

#### 1. First CI run of the drift workflow

**Test:** Open a PR touching `test/src/**` and let `.github/workflows/drift.yaml` run.
**Expected:** protoconf 0.2.0-rc2 installs and passes its sha256 check; `cd test && make test`
succeeds — including its new `make gates` step — and the diff over the three asserted trees is
empty on an already-current tree.
**Why human:** Confirmed still never executed: `gh run list --workflow drift.yaml` returns
`HTTP 404: workflow drift.yaml not found on the default branch`. Reproducibility was measured
on darwin/arm64 with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64
(assumption A1, 01-RESEARCH.md). Gap closure also added a shell-heavy Make target
(`mktemp`/`trap`/`sed`/`grep`) that has never run on a GitHub runner.

#### 2. Decide `GetConfigs`' config-key collision (CR-01) before Phase 2

**Test:** Decide whether `collect_configs` should refuse to overwrite a differing config at the
same `"<domain>/<name>/<config key>"` — the `_producers` duplicate-state idiom this repository
already uses — or whether the collapse is accepted.
**Expected:** Either a `fail()` on divergent configs at one key, or a recorded decision.
**Why human:** Specification-level, outside every Phase 1 criterion, and strictly pre-existing
(byte-identical at `init`). But `SelectComponents` now correctly delivers both live objects of
a diamond, and `GetConfigs` renders one: measured `leaf_occurrences=2 selected=2
config_keys=["leaf/infra/main.tf.json"]`. Phase 2 COST-02 ("every Terraform resource emitted by
every driver carries the cost-attribution tags") and Phase 5 SEC-01/SEC-03 all write through a
selection into configs, so a hook that writes anything arm-specific loses one arm before the CI
driver sees it — and `_producers`' duplicate-state `fail()` only ever sees the survivor.

#### 3. Confirm or correct 01-04's concurrency backstop truth

**Test:** Run `make gates` twice concurrently on a machine other than this one, or add a
held-out check for the collision.
**Expected:** Per the plan: the collision surfaces as a compile error naming a missing or
half-written probe, never as a green run that skipped a gate.
**Why human:** Tagged `verification: backstop` and covered by no committed check. Directly
observed 6/6 concurrent pairs here: both runs green, both having verified both gate messages
from their own `mktemp` logs, no residue, fixture sha unchanged. The safety half held every
time and holds structurally. The stated mechanism did not occur — collisions are benign because
both runs write byte-identical probe content from the same committed fixture. Either reword the
truth to the property that actually holds, or add the held-out check.

#### 4. Decide the scope of the drift assertion (CR-03 + WR-07)

**Test:** Decide whether `paths:` and the `git add` pathspec widen from the literal
`.github/workflows/terraform.yaml` to `.github/workflows/**`, whether `test/Makefile` joins the
trigger list, and whether `make workflows` should prune what it no longer generates.
**Expected:** A decision recorded either way.
**Why human:** Reproducing it requires committing a rename, which this verification would not
do. Re-confirmed unchanged, and 01-04 raised the stake: `test/Makefile` now decides whether the
gates run at all, and it matches no drift trigger.

### Gaps Summary

**No gaps. Both of the prior report's failed truths are closed, and both closures were
re-measured by re-running the exact falsification that defined the gap — not by reading a
SUMMARY.**

Gap 2 is closed by `make gates`, invoked from `make test` and therefore covered by
`drift.yaml` with no workflow edit. The check is falsifiable in four independent ways and was
falsified in all four: both gate calls deleted, each gate deleted alone, and the substitution
anchor broken. Each produced the correct, distinct diagnostic. Its central design choice is
vindicated by measurement, not argument — with both gates deleted, the mutated compile still
exits non-zero from `_producers`' duplicate-state `fail()`, so an exit-code assertion would
have reported a deleted gate as firing; the message-plus-traceback assertion caught it. The
cleanup contract holds under interruption at four points inside a 0.38-second window, and the
tracked fixture never moves.

Gap 1 is closed by `SelectComponents` returning a list of every occurrence. Measured on an
independently written diamond probe, not the committed fixture: both occurrences returned,
mutation through the selection reaches both live objects, and re-selecting after that mutation
returns the same two — the property that was 1-then-2 before. The committed fixture that
asserts this was itself falsified against the reverted implementation, twice, so it is not
vacuous. The post-order is `['leaf','base','mid1','leaf','mid2','top']`; the prior report's
proposed list was wrong and was correctly not used.

The phase is not `passed` for one reason and one reason only: **four items genuinely require a
human, and none of them is an invented manual step.** The drift workflow has still never
executed on GitHub — a 404 from the API, not an inference — and it is the sole mechanism behind
SC-1, now carrying a shell-heavy Make target on an OS/compiler pair this repository has never
built on. 01-04 published a concurrency truth it explicitly tagged `backstop`, and direct
measurement contradicts its stated mechanism while confirming its safety property; certifying
it VERIFIED would be dishonest and calling it a gap would be wrong. CR-01 is a real hole in
exactly the operation Phases 2 and 5 are built on, and is a specification decision rather than
an execution slip — the same shape as the `SelectComponents` contract question the previous
report routed to a human, which that human then answered at 01-05's checkpoint. And CR-03/WR-07
is unchanged and now slightly worse, because the file that decides whether the gates run is not
in any drift trigger.

All five requirements (FOUND-01..05) are satisfied. The bookkeeping in REQUIREMENTS.md is
inverted (WR-02) and should be corrected to all-Complete, not left as-is.

---

_Verified: 2026-09-08T10:45:00Z_
_Verifier: Claude (gsd-verifier)_
