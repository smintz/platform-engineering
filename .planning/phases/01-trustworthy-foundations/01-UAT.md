---
status: testing
phase: 01-trustworthy-foundations
source: [01-VERIFICATION.md]
started: 2026-09-08T10:50:00Z
updated: 2026-09-08T10:50:00Z
---

## Current Test

number: 1
name: First CI run of the drift workflow
expected: |
  The workflow installs protoconf 0.2.0-rc2 (sha256 verified), runs `cd test && make test` —
  which now also runs `make gates` — and the diff over the three asserted trees is empty on an
  already-current tree.
awaiting: user response

## Tests

### 1. First CI run of the drift workflow

expected: On a PR touching `test/src/**`, `.github/workflows/drift.yaml` installs protoconf 0.2.0-rc2 (sha256 verified), runs `cd test && make test` including the new `make gates`, and the diff over the three asserted trees is empty on an already-current tree.
result: [pending]
why_human: The workflow has still never executed — `gh run list --workflow drift.yaml` returns HTTP 404 (`not found on the default branch`). Byte-reproducibility was measured only on darwin/arm64 with a locally-built `protoconf 0.0.1`; CI pins 0.2.0-rc2 on linux_amd64. Assumption A1 in 01-RESEARCH.md, still open, unclosable from this machine. It now also carries `make gates`, which shells out to `sed`/`grep`/`mktemp` on a runner this repo has never exercised.

### 2. Decide whether `GetConfigs`' silent config overwrite is acceptable (CR-01)

expected: Either `collect_configs` refuses to overwrite a differing config at the same `"<domain>/<name>/<config key>"` (the `_producers` duplicate-state idiom this repo already has), or a decision is recorded accepting the collapse.
result: [pending]
why_human: Specification-level decision, outside every Phase 1 success criterion. Measured on this checkout — a diamond whose leaf carries a `WithState` config gives `leaf_occurrences=2 selected=2 config_keys=["leaf/infra/main.tf.json"]`. Strictly pre-existing: `configs[prefix + "/" + key] = cfg` is byte-identical at the `init` commit (ba9c1aa), so this phase neither introduced it nor changed `GetConfigs`. It matters because Phase 2 COST-02 and Phase 5 SEC-01/SEC-03 all write through a selection into configs.

### 3. Concurrent `make gates` collision (backstop truth)

expected: Per 01-04-PLAN's backstop truth, a collision on the two fixed probe filenames surfaces as a compile error naming a missing or half-written probe, never as a green run that skipped a gate.
result: [pending]
why_human: Tagged `verification: backstop` by the plan and covered by no committed check. Observed 6/6 concurrent pairs here: both runs exit 0, both print `gates: both compile gates fired`, no probe residue, fixture sha unchanged. The safety half held every time and holds structurally (each run greps its own `mktemp` log, so green implies the message was seen), but the stated MECHANISM never occurred — the collision is benign, because both runs write byte-identical probe content from the same committed fixture. Verifier abstained (`insufficient_spec`) rather than certify.

### 4. Decide the scope of the drift assertion (CR-03 + WR-07)

expected: Either `paths:` and the `git add` pathspec widen from the literal `.github/workflows/terraform.yaml` to `.github/workflows/**`, `test/Makefile` joins the trigger list, and `make workflows` prunes what it no longer generates — or the risk is accepted and recorded.
result: [pending]
why_human: Reproducing it requires committing a rename, which verification would not do. Re-confirmed unchanged and slightly worse: `test/Makefile` now decides whether the gates run at all, and it matches no drift trigger. `make workflows` is still `mkdir -p` + `cp` with no prune, and `drift.yaml` still filters on the literal filename — which is `TerraformPipeline`'s overridable `name` default. Consequence: a live root workflow carrying `terraform apply -auto-approve` behind a daily cron survives a rename of the definition that produced it.

## Summary

total: 4
passed: 0
issues: 0
pending: 4
