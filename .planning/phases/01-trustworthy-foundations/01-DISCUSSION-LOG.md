# Phase 1: Trustworthy Foundations - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-09-07
**Phase:** 1-Trustworthy Foundations
**Areas discussed:** Drift-check placement, Drift-check scope, Component shape field, SelectComponents semantics, Enforcement location
**Mode:** `--auto` — Claude selected the recommended option for every question; no user prompts were shown.

---

## Drift-check placement

| Option | Description | Selected |
|--------|-------------|----------|
| Hand-written standalone workflow | A separate `.github/workflows/` file, authored by hand, that recompiles and diffs | ✓ |
| Job inside the generated pipeline | Emit the check from `github_actions.pinc` into `terraform.yaml` | |
| Makefile target only | A `make drift` target CI happens to call | |

**Choice:** Hand-written standalone workflow (recommended default)
**Notes:** The artifact being checked is the generated pipeline itself. A generated check can be silently omitted by the very staleness it guards against — a stale `terraform.yaml` ships without its own guard. The checker must not be the checked. This is the one place hand-written CI is correct in a repo whose convention is "the workflow is generated, edit the `.mpconf`".

---

## Drift-check scope

| Option | Description | Selected |
|--------|-------------|----------|
| `test/` trees + copied root workflow; delete orphan root trees | Diff `test/materialized_config/`, `test/outputs/`, `.github/workflows/terraform.yaml`; `git rm` the unreachable root `outputs/`+`materialized_config/` | ✓ |
| All four trees including root | Also diff root `outputs/`/`materialized_config/` | |
| `test/outputs/` only | Narrowest scope | |

**Choice:** `test/` trees + copied root workflow, with the orphan root trees deleted
**Notes:** The root trees describe an `aurora-user-api-task` component present in no `.mpconf`, and the root build that would regenerate them cannot run (no root `CONFIGSPACE`; `src/terraform/v1/util.pinc` loads a `terraform.proto` that lives only under `test/src/`). Diffing a tree nothing generates makes "is the output current?" unanswerable. Trigger paths were also changed to source paths — the existing pipeline triggers on `test/outputs/**`, which by construction cannot fire for "source edited, output not regenerated".

---

## Component shape field

| Option | Description | Selected |
|--------|-------------|----------|
| Reuse existing `Component.Metadata.labels` | `map<string,string>` already in the schema, currently unused by any Starlark | ✓ |
| Add new `Component.tags` field | What research SUMMARY.md proposed | |
| Use `Component.Metadata.tags` (repeated string) | The other existing field | |

**Choice:** Reuse `Component.Metadata.labels`
**Notes:** This overrides the research recommendation. `src/platform/v1/platform.proto` already declares `Metadata { repeated string tags = 1; map<string,string> labels = 2; }`. A grep across `src/platform/*.pinc`, `drivers/*/*/src/*.pinc`, and `test/src/core_test.mpconf` confirms neither field is written or read anywhere — the only `metadata` hits are the Kubernetes provider's own resource metadata. Research read `ARCHITECTURE.md` rather than the `.proto` and so proposed adding a field that already exists under a different name. Adding a second creates two overlapping shape vocabularies, which is exactly what makes a selector unauditable. `Metadata.tags` stays unused for the same reason.

---

## SelectComponents semantics

| Option | Description | Selected |
|--------|-------------|----------|
| Factor out `walk_upstreams`, de-duplicate, return list | Reuse the proven traversal; de-dupe by identity in the selector only | ✓ |
| Write a fresh traversal for selection | Independent implementation | |
| Reuse traversal as-is, no de-duplication | Match `GetConfigs` behavior exactly | |

**Choice:** Factor out, de-duplicate in `SelectComponents`, leave `GetConfigs` untouched
**Notes:** The existing traversal (`core.pinc:205`) does not de-duplicate. `GetConfigs` survives that because it keys results by `"<domain>/<name>/<config>"`, so a diamond dependency's repeats collapse silently. A selector has no such key — a component reached by two paths would be returned twice and a policy hook applied twice. De-duplicating inside `GetConfigs` would risk changing its output, and the golden-file diff must stay empty; so the de-dupe lives in the selector.

---

## Enforcement location (FOUND-04, FOUND-05)

| Option | Description | Selected |
|--------|-------------|----------|
| Compile-time check inside `TerraformPipeline` | Beside the existing job-id collision `fail()` in the CI driver | ✓ |
| `.proto-validator` on `Component` | What CONVENTIONS.md generally prefers | |
| `fail()` in the state driver | Where backends are defined | |

**Choice:** Inside the CI driver's `TerraformPipeline`
**Notes:** `CONVENTIONS.md` does prefer a validator over a driver `fail()`, and that guidance is right for anything expressible about a `Component` in isolation — it does not apply here. Both FOUND-04 and FOUND-05 assert something about the relationship between a config and *the pipeline that will apply it*. A validator bound to `Component` cannot see the pipeline. `TerraformPipeline` is the only place that knows which configs get apply jobs and how ordering was derived, so it is the only place the assertion can be true. A consequence surfaced here: enabling FOUND-04 immediately breaks the reference stack, because `test/src/core_test.mpconf:50` is the live instance of the bug — so the same plan must pass `BACKEND` to `RedisComponent`, producing one deliberate, expected golden-file diff.

---

## Claude's Discretion

Auto mode selected the recommended option for all five areas. Latitude left to the planner:

- Exact workflow YAML structure and action versions for the drift check
- The precise `SelectComponents` predicate calling convention (component message vs. wrapper)
- Internal helper naming
- Whether `walk_upstreams` keeps its `next`-callback shape or becomes a plain collector once factored out

## Deferred Ideas

Surfaced during scouting/research, outside FOUND-01..05 — full detail in `01-CONTEXT.md`:

- The 161-line `src/terraform/v1/util.pinc` vs `test/src/terraform/v1/util.pinc` fork, where only the unimported copy has the fixes
- `Walk` iterating `component.upstreams` instead of `component.upstreams.components` (`util.pinc:161`)
- Root build is decorative — no root `CONFIGSPACE`/lock; `src/` cannot compile standalone
- Root `providers.tf` orphaned, unpinned
- `test/protoconf.lock` commits absolute local paths
- S3 backend has no state locking, while the workflow passes a meaningless `-lock-timeout`
- Schema-level validation (`buf.validate.field`, `.proto-validator`) — adjacent in spirit, not required by FOUND-01..05
- `TODO(smintz)` in `Component.Objective.Check`
