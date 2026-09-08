---
status: complete
phase: 01-trustworthy-foundations
source: [01-VERIFICATION.md, 01-01-SUMMARY.md, 01-02-SUMMARY.md, 01-03-SUMMARY.md, 01-04-SUMMARY.md, 01-05-SUMMARY.md]
started: 2026-09-08T10:50:00Z
updated: 2026-09-08T04:19:08Z
---

## Current Test

[testing complete]

## Tests

### 1. First CI run of the drift workflow

expected: On a PR touching `test/src/**`, `.github/workflows/drift.yaml` installs protoconf 0.2.0-rc2 (sha256 verified), runs `cd test && make test` including the new `make gates`, and the diff over the three asserted trees is empty on an already-current tree.
result: pass
why_human: The workflow has still never executed — `gh run list --workflow drift.yaml` returns HTTP 404 (`not found on the default branch`). Byte-reproducibility was measured only on darwin/arm64 with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64. Assumption A1 in 01-RESEARCH.md, still open, unclosable from this machine. It now also carries `make gates`, which shells out to `sed`/`grep`/`mktemp` on a runner this repo has never exercised.

### 2. Decide whether `GetConfigs`' silent config overwrite is acceptable (CR-01)

expected: Either `collect_configs` refuses to overwrite a differing config at the same `"<domain>/<name>/<config key>"` (the `_producers` duplicate-state idiom this repo already has), or a decision is recorded accepting the collapse.
result: pass
why_human: Specification-level decision, outside every Phase 1 success criterion. Measured on this checkout — a diamond whose leaf carries a `WithState` config gives `leaf_occurrences=2 selected=2 config_keys=["leaf/infra/main.tf.json"]`. Strictly pre-existing: `configs[prefix + "/" + key] = cfg` is byte-identical at the `init` commit (ba9c1aa), so this phase neither introduced it nor changed `GetConfigs`. It matters because Phase 2 COST-02 and Phase 5 SEC-01/SEC-03 all write through a selection into configs.

### 3. Concurrent `make gates` collision (backstop truth)

expected: Per 01-04-PLAN's backstop truth, a collision on the two fixed probe filenames surfaces as a compile error naming a missing or half-written probe, never as a green run that skipped a gate.
result: pass
why_human: Tagged `verification: backstop` by the plan and covered by no committed check. Observed 6/6 concurrent pairs here: both runs exit 0, both print `gates: both compile gates fired`, no probe residue, fixture sha unchanged. The safety half held every time and holds structurally (each run greps its own `mktemp` log, so green implies the message was seen), but the stated MECHANISM never occurred — the collision is benign, because both runs write byte-identical probe content from the same committed fixture. Verifier abstained (`insufficient_spec`) rather than certify.

### 4. Decide the scope of the drift assertion (CR-03 + WR-07)

expected: Either `paths:` and the `git add` pathspec widen from the literal `.github/workflows/terraform.yaml` to `.github/workflows/**`, `test/Makefile` joins the trigger list, and `make workflows` prunes what it no longer generates — or the risk is accepted and recorded.
result: pass
why_human: Reproducing it requires committing a rename, which verification would not do. Re-confirmed unchanged and slightly worse: `test/Makefile` now decides whether the gates run at all, and it matches no drift trigger. `make workflows` is still `mkdir -p` + `cp` with no prune, and `drift.yaml` still filters on the literal filename — which is `TerraformPipeline`'s overridable `name` default. Consequence: a live root workflow carrying `terraform apply -auto-approve` behind a daily cron survives a rename of the definition that produced it.

### 5. Read the new `core.pinc` comments (01-02 D6)

expected: `GetConfigs`' doc comment still sits directly above its own `def` — it did not become an orphan when `walk_upstreams` was lifted out — and each newly-added symbol (`walk_upstreams`, `SelectComponents`, `WithLabels`) carries a rationale comment that says WHY it exists, in the register of the surrounding file, rather than restating WHAT the next line does.
result: pass
coverage_id: 01-02/D6
why_human: The plan's own `<human-check>`. No grep distinguishes an orphaned doc comment from an intentional one, or judges whether a comment explains rather than narrates.

### 6. Read the `dependencies` comment in the GitHub Actions driver (01-03 D6)

expected: The comment above `dependencies` in `drivers/cicd/github_actions/src/github_actions.pinc` describes the behaviour the driver now has after D-17, and is honest about the tolerance D-17 traded away — rather than still arguing for it. The superseded `pretending otherwise` text is grep-confirmed gone; what replaced it is what needs reading.
result: pass
coverage_id: 01-03/D6
why_human: A grep proves the old text is gone; only a reader can tell whether the replacement is honest about the trade.

<!-- Entries below are deterministically covered by passing verification refs in the SUMMARY coverage blocks (#1602). Not presented for manual testing. -->

### 7. Drift fails on an unregenerated build

expected: A push or PR editing test/src/**, src/**, drivers/** or test/CONFIGSPACE without a regenerated build fails the drift workflow
result: pass
source: automated
coverage_id: 01-01/D1

### 8. Drift fails on a NEW output file

expected: A change that ADDS a new output file — a new component's new state directory — also fails the drift check, because the assertion stages before it diffs
result: pass
source: automated
coverage_id: 01-01/D2

### 9. Drift workflow holds least privilege

expected: contents:read only, no OIDC, no secrets, no terraform install, no fork-context trigger, compiler pinned by version and sha256
result: pass
source: automated
coverage_id: 01-01/D3

### 10. Exactly one generated-output tree

expected: Orphan root outputs/ and materialized_config/ trees are gone; the test/ build is undisturbed by their removal
result: pass
source: automated
coverage_id: 01-01/D4

### 11. WithLabels lands in Component.Metadata.labels

expected: `platform.WithLabels(tier = "cache")` lands the pair in `Component.Metadata.labels`, including on a component whose `metadata` was never constructed
result: pass
source: automated
coverage_id: 01-02/D1

### 12. SelectComponents traversal contract

expected: Returns every matching component in the dependency graph in post-order, and [] when nothing matches
result: pass
source: automated
coverage_id: 01-02/D2

### 13. Traversal lift is behaviour-preserving

expected: Lifting the traversal out of `GetConfigs` recompiles the reference stack to byte-identical output (D-12)
result: pass
source: automated
coverage_id: 01-02/D3

### 14. Both symbols reach call sites via the platform facade

expected: No new load edge; proto schema untouched
result: pass
source: automated
coverage_id: 01-02/D4

### 15. No planning artifact names Component.tags

expected: REQUIREMENTS.md and ROADMAP.md name `Component.Metadata.labels`, never the `Component.tags` field D-07 decided against
result: pass
source: automated
coverage_id: 01-02/D5

### 16. Redis Terraform state held in S3

expected: State is in S3 rather than on the CI runner's disk, so an apply no longer plans against nothing and recreates the deployment every run
result: pass
source: automated
coverage_id: 01-03/D1

### 17. Local-backend component fails at compile time

expected: A component whose state CI will apply but that renders a local backend fails at compile time, naming that component and naming BACKEND as WithState's second argument
result: pass
source: automated
coverage_id: 01-03/D2

### 18. Unproduced remote-state read fails at compile time

expected: A `terraform_remote_state` read whose state id matches no other config's backend state id fails at compile time with a message naming both fixes
result: pass
source: automated
coverage_id: 01-03/D3

### 19. Paired handshake compiles and produces the ordering edge

expected: Compiles silently AND the reader's plan job waits on the writer's — sub -> [pub], pub -> []
result: pass
source: automated
coverage_id: 01-03/D4

### 20. Guards change no generated output

expected: Adding two compile-time guards changes no generated output; the generated workflow stays byte-identical after the redis backend fix
result: pass
source: automated
coverage_id: 01-03/D5

### 21. make gates reproduces both negative checks

expected: Reproduces both negative compile checks from the committed fixture, exits 0 printing `gates: both compile gates fired` on an unmodified checkout
result: pass
source: automated
coverage_id: 01-04/D1

### 22. Deleting either compile gate is a red build

expected: With both gate calls replaced by `pass`, `make test` exits non-zero and prints a `gate did not fire` line — the exact mutation that gave exit 0 in 01-VERIFICATION.md
result: pass
source: automated
coverage_id: 01-04/D2

### 23. Gate verdict comes from the message, not the exit code

expected: The target decides gate-fired from the compiler's message and traceback function, never from the exit code, and confirms each substitution landed before interpreting the compile
result: pass
source: automated
coverage_id: 01-04/D3

### 24. make gates is idempotent and edits no tracked file

expected: Never edits a tracked file, leaves no probe copy behind, `git status --porcelain` byte-identical across consecutive runs
result: pass
source: automated
coverage_id: 01-04/D4

### 25. Fixture comments name the command and the catching functions

expected: `test/src/handshake_test.mpconf` names `make gates` and both gate function names, replacing a pointer to a plan task and a wrong-gate attribution
result: pass
source: automated
coverage_id: 01-04/D6

### 26. SelectComponents returns every occurrence

expected: Every occurrence of a matching component in a diamond, in `walk_upstreams`' post-order — ['leaf','base','mid1','leaf','mid2','top']
result: pass
source: automated
coverage_id: 01-05/D1

### 27. Mutation across a selection reaches both embedded leaves

expected: Stamp-and-read-back through `occurrences(root, [])` gives [STAMP, STAMP] — the property Phase 5 SEC-01 and Phase 2 COST-01 consume
result: pass
source: automated
coverage_id: 01-05/D2

### 28. Selection is idempotent with respect to mutation

expected: Same list before and after mutating through it — ['leaf','leaf'] after stamping (was 1 then 2)
result: pass
source: automated
coverage_id: 01-05/D3

### 29. FOUND-03 empty and single-element edges

expected: A predicate nothing matches returns [] without failing; a root with no upstreams that matches returns exactly itself
result: pass
source: automated
coverage_id: 01-05/D4

### 30. GetConfigs output unchanged after the every-occurrence change

expected: `test/materialized_config/`, `test/outputs/` and `.github/workflows/terraform.yaml` byte-identical after a full rebuild (D-12)
result: pass
source: automated
coverage_id: 01-05/D5

### 31. walk_upstreams visitor rename

expected: Visitor parameter renamed from `next` to `visit`, both call sites still positional, still one traversal with two consumers (D-10)
result: pass
source: automated
coverage_id: 01-05/D6

## Summary

total: 31
passed: 31
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

[none yet]
