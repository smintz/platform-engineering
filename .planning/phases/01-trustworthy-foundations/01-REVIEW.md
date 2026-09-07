---
phase: 01-trustworthy-foundations
reviewed: 2026-09-08T01:05:00Z
depth: standard
files_reviewed: 10
files_reviewed_list:
  - .github/workflows/drift.yaml
  - .gitignore
  - drivers/cicd/github_actions/src/github_actions.pinc
  - src/platform/core.pinc
  - src/platform/platform.pinc
  - test/materialized_config/core_test/us-east-1/redis/infra/main.tf.json.materialized_JSON
  - test/outputs/core_test/us-east-1/redis/infra/main.tf.json
  - test/src/core_test.mpconf
  - test/src/handshake_test.mpconf
  - test/src/select_test.mpconf
findings:
  critical: 3
  warning: 10
  info: 6
  total: 19
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-09-08T01:05:00Z
**Depth:** standard
**Files Reviewed:** 10
**Status:** issues_found

## Summary

Reviewed the drift-check workflow, the two new compile gates in the GitHub Actions driver,
`WithLabels`/`SelectComponents` in the platform core, and the three `.mpconf` fixtures. The
two generated artifacts in scope (`redis/infra/main.tf.json` and its `.materialized_JSON`)
are consistent with `core_test.mpconf` — the S3 backend block matches `BACKEND`'s
`key_for`, and a clean `cd test && /usr/bin/make test` reproduces both byte-for-byte with an
empty `git status`.

Verification performed live rather than by reading:

- Both new gates were proven to fire by substituting `LOCAL`/`MISMATCHED` into temporary
  copies of `handshake_test.mpconf`; each produced its intended message and
  `protoconf compile .` exited 1 (fixtures removed, tree restored clean).
- `SelectComponents` was probed with a real diamond. It is **broken for its own stated use
  case** (CR-01) — proven, not inferred.
- `GetConfigs` was probed with a domain+name collision. It silently drops a component
  (WR-10) — proven.

Three defects rise to blocker. One is a correctness bug in new platform code that fails
silently in exactly the diamond topology it was written for. One is an unmet acceptance
criterion: the phase's headline guarantee (two compile gates) ships with zero automated
regression coverage and two dead constants justified only by an uncommitted script. One is
a hole in the drift check itself — the artifact it guards can go stale in a way it reports
green.

## Critical Issues

### CR-01: `SelectComponents` de-duplicates by value, so mutating the result silently skips the diamond's other arm

**File:** `src/platform/core.pinc:221-229`

**Issue:** The docstring justifies de-duplication with "a component reached down two arms of
a diamond is one component, and a policy hook applied to it twice is applied once too
often." That premise is false in this graph. `Component` (core.pinc:180-183) builds each
dependency factory **once per parent**, so the diamond is a tree with two *distinct*
`leaf` objects embedded at `mid1.upstreams.components[0]` and `mid2.upstreams.components[0]`.
`found[c] = True` collapses them by proto value equality, and the caller then holds exactly
one of the two live objects.

Proven by compiling a probe (`top -> {mid1, mid2} -> leaf`) against this code:

```
selected count: 1
mid1.leaf.description = "POLICY-APPLIED"      # mutated
mid2.leaf.description = ""                    # silently untouched
```

Which arm survives is a first-insertion-wins artifact of `walk_upstreams`' order, so the
component that escapes the policy is arbitrary.

The same probe also shows the function is not idempotent — mutating the survivor makes the
twins unequal, so the next call returns two:

```
pass 1 count: 1
pass 2 count (after mutating pass-1 survivor): 2
pass 3 count: 1
```

Any caller that applies a hardening rule, a cost-centre tag or a policy across a selection
therefore applies it to a subset that depends on call order, and re-running the same
selection returns a different set. `select_test.mpconf` cannot catch this: it asserts only
on `c.name`, never mutates, and never re-selects.

**Fix:** De-duplication by value cannot be made correct while the graph stores copies.
Return every occurrence and let de-duplication be the caller's decision, or — if the
dedup semantics are wanted — return the *group* so a mutation reaches all copies:

```python
# every occurrence, in post-order; a diamond's shared upstream appears once per arm
# because those arms hold distinct objects, and mutating one does not mutate the other
def SelectComponents(component, predicate):
    found = []

    def collect(c):
        if predicate(c):
            found.append(c)

    walk_upstreams(component, collect)
    return found
```

and update `select_test.mpconf` to assert `["leaf", "base", "mid1", "mid2", "leaf", "top"]`,
plus a new assertion that mutating the selection reaches **both** embedded `leaf` objects.
If a de-duplicated view is genuinely needed later, build it on top of this from
`"<domain>/<name>"`, where the uniqueness assumption is at least visible.

---

### CR-02: The two new compile gates have no automated regression test; `MISMATCHED` and `LOCAL` are dead code guarding nothing

**File:** `test/src/handshake_test.mpconf:41-64`, `test/Makefile:1-10`, `.github/workflows/drift.yaml:60-61`

**Issue:** `handshake_test.mpconf:26` states "those two negative checks are scripted from
outside the compiler rather than asserted here — see this plan's Task 3." No such script
exists in the repository. `find . -name '*.sh'` outside `.claude`/`.agents` returns nothing,
`test/Makefile` has one target (`test`) and one helper (`workflows`), and `drift.yaml` runs
`make test` only. The negative checks were executed by hand once during implementation
(`01-03-SUMMARY.md:77,85`) and are not reproducible by CI or by any committed command.

The consequence is concrete: delete either line from `TerraformPipeline`

```python
    _check_remote_backends(configs)     # github_actions.pinc:670
    _check_reads_are_produced(configs)  # github_actions.pinc:671
```

and `cd test && make test` still exits 0, `git diff` over the three drift-asserted trees is
still empty, and `drift.yaml` reports green. The phase's headline guarantee can be removed
without any check noticing.

This also leaves `MISMATCHED` (line 53) and `LOCAL` (line 60) as unreferenced module
constants. Their comment forbids deleting them as dead code on the grounds that they feed
the negative checks — but nothing runs those checks, so the constants currently guard
nothing and the comment is the only thing keeping them alive.

`01-03-PLAN.md:37` states the acceptance criterion as "proven to FIRE, not merely to exist,
by a committed probe with two named switch points and **two scripted negative checks**." The
probe is committed; the scripts are not. This ships as an unmet requirement.

**Fix:** Commit the two checks as a Makefile target and run it in `drift.yaml`. Both
mutations are anchored single-line `sed`s that the fixture was deliberately shaped for:

```make
# test/Makefile
GATES = handshake_test.mpconf

gates:
	@set -e; for m in "NEAR_BACKEND = BACKEND|NEAR_BACKEND = LOCAL|writes local Terraform state" \
	                  "FAR_BACKEND = BACKEND|FAR_BACKEND = MISMATCHED|no config in this pipeline writes"; do \
	  from=$${m%%|*}; rest=$${m#*|}; to=$${rest%%|*}; want=$${rest#*|}; \
	  cp src/$(GATES) /tmp/$(GATES).bak; \
	  sed -i.tmp "s|^$$from$$|$$to|" src/$(GATES); \
	  grep -qF "$$to" src/$(GATES) || { echo "gate check: mutation did not land"; exit 1; }; \
	  out=$$(protoconf compile . $(GATES) 2>&1); rc=$$?; \
	  cp /tmp/$(GATES).bak src/$(GATES); rm -f src/$(GATES).tmp; \
	  [ $$rc -ne 0 ] || { echo "gate check: compile succeeded, gate did not fire"; exit 1; }; \
	  case "$$out" in *"$$want"*) ;; *) echo "gate check: wrong message: $$out"; exit 1;; esac; \
	done; echo "both compile gates fire"

test: ...
	$(MAKE) gates
```

Assert on the message, not just the exit code — both mutations exit non-zero for several
reasons, which is the failure mode `01-03-SUMMARY.md:174` already hit once.

---

### CR-03: `drift.yaml` reports green on a renamed or added generated workflow, and `make workflows` never prunes the stale one

**File:** `.github/workflows/drift.yaml:70-72`, `test/Makefile:8-10`

**Issue:** The assertion stages three pathspecs, one of which is the **literal filename**
`.github/workflows/terraform.yaml`:

```yaml
git add -A -- test/materialized_config test/outputs .github/workflows/terraform.yaml
```

That filename is not a constant of the system — it is `TerraformPipeline`'s `name` default
(`github_actions.pinc:651`), overridable per call. And `make workflows` installs by copy
only:

```make
cp outputs/core_test/.github/workflows/*.yaml ../.github/workflows/
```

Change `name = "terraform"` to anything else, or add a second pipeline, and:

1. The new `.github/workflows/<new>.yaml` is untracked **and outside the `git add`
   pathspec**, so `git add -A` never stages it and the diff never sees it.
2. `terraform.yaml` at the repository root is never deleted by the copy, so it is unchanged
   and its diff is empty.
3. The check exits 0.

The repository then ships a stale root workflow that GitHub keeps scheduling — the generated
pipeline carries `schedule: cron 0 3 * * *` and `push: branches: [main]` with
`terraform apply -auto-approve` behind it. A stale `terraform.yaml` applying against a state
whose definition has moved is the drift class this file was written to make impossible, and
the file's own header comment ("the artifact this check guards IS the generated pipeline")
argues for exactly the coverage it does not have.

The `on.paths` trigger has the same literal (lines 15, 18), so a hand-edit of a *renamed*
workflow also matches no trigger.

**Fix:** Stage and trigger on the directory, not the filename, so an added file is visible:

```yaml
on:
  pull_request:
    paths: [test/src/**, src/**, drivers/**, test/CONFIGSPACE, test/Makefile, .github/workflows/**]
  push:
    branches: [main]
    paths: [test/src/**, src/**, drivers/**, test/CONFIGSPACE, test/Makefile, .github/workflows/**]
```

```yaml
      - name: assert generated output is current
        run: |
          git add -A -- test/materialized_config test/outputs .github/workflows
          git diff --cached --exit-code -- \
            test/materialized_config test/outputs .github/workflows \
          || { echo "::error::generated output is stale. Run 'cd test && make test' and commit the result."; exit 1; }
```

`drift.yaml` itself is tracked and unmodified by the build, so widening the pathspec adds no
false positive. Separately, make the install prune so a rename cannot leave a live orphan —
copy into a subdirectory the build owns outright, or drop the generated set explicitly:

```make
workflows:
	mkdir -p ../.github/workflows
	git -C .. ls-files -z .github/workflows | grep -zv 'drift.yaml$$' | xargs -0r rm -f
	cp outputs/core_test/.github/workflows/*.yaml ../.github/workflows/
```

## Warnings

### WR-01: `pull-requests: write` and `id-token: write` are granted workflow-wide, including to every job that runs contributor Terraform

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:733-738`

**Issue:** `lib.Permissions(...)` is emitted at workflow scope, so all nine plan/apply jobs
hold `pull-requests: write` even though only `pr_comment` (line 607) ever writes to the PR,
and hold `id-token: write` regardless of whether their credentials helper uses OIDC. Plan
jobs execute `terraform init`/`validate`/`plan`, which runs provider and external-data code
from the branch under review. `drift.yaml:23-24` states the opposite principle for itself
("runs contributor-authored Starlark through a compiler, so it must never hold a
write-scoped token"); the pipeline it guards does not follow it.

**Fix:** Keep the workflow scope at `contents: read` and push the writes down to the jobs
that need them — `lib.Permissions(**{"pull-requests": "write"})` inside `_comment_job`, and
`**{"id-token": "write"}` inside `_plan_job`/`_apply_job`.

---

### WR-02: `GRAFANA_TOKEN_SCRIPT` interpolates GitHub expressions straight into a shell script body

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:307-340, 364-370`; `test/src/core_test.mpconf:128`

**Issue:** `workspace`, `plan_account` and `apply_account` are substituted into the script
text at compile time and land inside the `run:` body. The call site passes
`workspace = "${{ vars.GRAFANA_WORKSPACE_ID }}"`, which GitHub expands into the script
*before* bash parses it. A variable value of `x"; curl … | sh; #` executes arbitrary
commands on a runner that has already assumed the plan or apply AWS role. Repository
variables are admin-controlled so this is not remotely reachable today, but it is the
standard Actions script-injection shape and costs nothing to close.

**Fix:** Pass the values through `env` and reference them as shell variables, so the
expression is never part of the script text:

```python
lib.Step(
    "grafana-token",
    lib.SetEnv(GRAFANA_WS = workspace, GRAFANA_SA = plan_account if phase == "plan" else apply_account),
    lib.Cmd(GRAFANA_TOKEN_SCRIPT % {"ttl": seconds_to_live}),
)
```
with the script reading `ws="$GRAFANA_WS"` / `account="$GRAFANA_SA"`.

---

### WR-03: `GetConfigs` silently drops a component when two components share domain and name

**File:** `src/platform/core.pinc:235-258`

**Issue:** `configs[prefix + "/" + key] = cfg` is a plain assignment. Two distinct
components with the same `name` in the same domain map to one key and the second overwrites
the first. Proven:

```
config keys: ["d/dup/infra/main.tf.json"]      # two components declared, one config emitted
```

The vanished component gets no Terraform, no plan job and no apply job, with no error
anywhere. It also defeats the job-id collision guard added at
`github_actions.pinc:676-684` — that guard iterates `configs.keys()` and therefore only ever
sees one key, so the collision is already resolved by the time the loud check runs. The
phase added the guard one layer above where the loss happens.

**Fix:** Fail on a key collision whose contents differ. The equal-content case must stay
silent, because a genuine diamond visits the same upstream twice and legitimately produces
the same key with identical bytes:

```python
            path = prefix + "/" + key
            if path in configs and str(configs[path]) != str(cfg):
                fail(
                    ("two different components produce the config %s — a component's " +
                     "domain and name together have to be unique, because that pair is " +
                     "the config's path and the pipeline's job id") % path,
                )
            configs[path] = cfg
```

---

### WR-04: The Terraform plugin cache key is constant, so the cache is never invalidated

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:475-485`

**Issue:** The key is
`"tf-plugins-%s-${{ hashFiles('%s/.terraform.lock.hcl') }}"`, but that lock file does not
exist when the cache step runs: `.terraform.lock*` is gitignored (`.gitignore:38`) and the
comment at line 486-487 confirms "the lock file is written by this very init" — which
happens in the *next* step. `hashFiles` on no match returns the empty string, so every run
of every state uses the literal key `tf-plugins-<slug>-`, identical to its own
`restore-keys`. Once saved, `actions/cache` gets a key hit forever and never re-saves, so a
provider version bump downloads the new plugin on every run and the cache holds the old set
indefinitely. The verbatim key is visible in the generated
`.github/workflows/terraform.yaml:34-38`.

**Fix:** Key on something that exists at cache time and changes when the providers do — the
generated config that pins them:

```python
"key": "tf-plugins-%s-%s-${{ hashFiles('%s/*.tf.json') }}" %
       (_slug(directory), terraform_version, directory),
```

---

### WR-05: `test/protoconf.lock` is committed containing machine-local absolute paths

**File:** `.github/workflows/drift.yaml:49-56`, `.gitignore` (missing entry)

**Issue:** The committed lock pins each module by `file:///Users/smintz/git/platform-engineering/...`.
That path is valid on exactly one machine, so every other contributor's `protoconf mod tidy`
rewrites the file, and CI has to `rm -f` it before it can build. Deleting a committed
integrity artefact to make the build work is a workaround, not a pin. Worse, `drift.yaml`
lists `test/protoconf.lock` in both `paths:` filters (lines 15, 18), so the churn it causes
triggers drift runs whose first real action is to delete the file that triggered them.

**Fix:** Add `test/protoconf.lock` to `.gitignore`, `git rm --cached` it, drop it from both
`paths:` lists, and keep the `rm -f` as belt-and-braces. Every `remote_repo` in
`test/CONFIGSPACE` is a relative path inside this checkout, so the lock pins nothing the
checkout does not already pin.

---

### WR-06: `handshake_test.mpconf` names the wrong gate for the `LOCAL` substitution

**File:** `test/src/handshake_test.mpconf:118-124`

**Issue:** The comment claims "LOCAL collapses both backend state ids to `local://`, which
the duplicate-state `fail()` inside `_producers` reports." It does not. `TerraformPipeline`
runs `_check_remote_backends` first (github_actions.pinc:670), and the substitution actually
produces:

```
[@github_actions//github_actions.pinc:204:17] TerraformPipeline: handshake/pub/infra writes
local Terraform state, and CI applies it on a runner whose disk is discarded ...
  @github_actions//github_actions.pinc:204:17: in _check_remote_backends
```

`_producers` is never reached. The comment's whole purpose is to tell a future maintainer
where to look when a gate stops firing; it points at the wrong function, and the surrounding
argument for call ordering rests on the false claim.

**Fix:** Replace the parenthetical with the message the check actually produces —
"`_check_remote_backends` rejects the local backend before `dependencies` is ever entered" —
and keep the ordering argument, which is independently correct.

---

### WR-07: `test/Makefile` is not in `drift.yaml`'s trigger paths

**File:** `.github/workflows/drift.yaml:15, 18`

**Issue:** `test/Makefile` is the build recipe — it runs `protoconf compile` and, in
`workflows:`, decides which generated yaml is installed at the repository root. A PR whose
only change is to that file alters what CI produces and matches no trigger, so the drift
check does not run on it. Every other input to the build (`test/src/**`, `src/**`,
`drivers/**`, `test/CONFIGSPACE`) is listed.

**Fix:** Add `test/Makefile` to both `paths:` lists (folded into the CR-03 fix above).

---

### WR-08: `PLAN_COMMENT_SCRIPT` only sees the first page of comments, so it appends a new plan comment on busy PRs

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:434-439`

**Issue:** `github.rest.issues.listComments` returns 30 comments by default and no
pagination is requested. On a PR with more than 30 comments, `prev` is `undefined` and the
`createComment` branch runs on every push, appending a fresh plan comment each time — which
is the "N-1 lost updates" outcome the comment block at lines 376-384 says this design exists
to avoid.

**Fix:**

```js
const comments = await github.paginate(github.rest.issues.listComments,
  { ...context.repo, issue_number: context.issue.number, per_page: 100 });
const prev = comments.find(c => c.body.startsWith(tag));
```

---

### WR-09: The comment budget can go negative and still overflow GitHub's limit

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:421-433`

**Issue:** `share = Math.floor((BUDGET - header.length) / changed.length) - 200`. Nothing
bounds `header.length` — it grows one table row per config, unbounded. Once the header alone
exceeds `BUDGET`, `share` is negative, `Math.max(share, 0)` truncates every plan body to the
empty string, and `out` is still `header`, which can already exceed the 65536 hard limit.
The API then rejects the comment with a 422 and the job fails, so a large stack gets no plan
comment at all — the exact outcome the budget was introduced to prevent.

**Fix:** Clamp the final string as well as the shares:

```js
let out = header + '\n' + details;
if (out.length > 65000) out = out.slice(0, 64900) + '\n\n_... truncated, see the artifacts_';
```

---

### WR-10: Gate error messages instruct the caller in terms of a symbol from one caller's file

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:199-224`

**Issue:** All three new `fail()` messages end with "Pass BACKEND as the second argument to
`WithState(...)` for this component." `BACKEND` is a local variable name in
`test/src/core_test.mpconf:9`, not part of any API, and `WithState` belongs to the terraform
state driver — which this file's own header (lines 5-11) says it knows nothing about
("it knows how to run Terraform in CI and nothing about which components exist"). The advice
is wrong for any caller who named their backend differently or reached `TerraformPipeline`
without `WithState` at all.

**Fix:** State the requirement, not one caller's spelling: "give this config a Terraform
backend this pipeline can also apply (any non-local backend `_backend_state_id` can name)".
The third message's second half ("or teach `_backend_state_id` the backend it uses") is
already the right register.

## Info

### IN-01: `walk_upstreams` has a hook's signature but is not a hook

**File:** `src/platform/core.pinc:204-209`

Promoted to module level by this phase, `walk_upstreams(component, next)` matches the
repo-wide `(msg, next)` hook shape exactly, but `next` is a visitor callback and the return
values of the recursive calls are discarded — only the final `next(component)` propagates.
A future caller who passes a transforming hook loses every upstream result silently.
Rename the parameter to `visit`, and drop the unused return, to make the difference visible.

### IN-02: `dependencies` documents a precondition it cannot enforce

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:132-156, 754`

The docstring now asserts "Every read that reaches this function resolves to a config in the
map … a compile error raised by `_check_reads_are_produced` before this function runs." But
`dependencies` is exported in the `actions` struct and is callable directly — as
`handshake_test.mpconf:139` does. The defensive `if state and state in producer` filter on
line 150 is what actually holds the invariant; the comment reads as if it were removable.

### IN-03: `_producers` is rebuilt twice per pipeline

**File:** `drivers/cicd/github_actions/src/github_actions.pinc:671, 673`

`_check_reads_are_produced` and `dependencies` each call `_producers`, so the map is built
twice and the duplicate-state `fail()` is reachable from two different tracebacks. Passing
the producer map into both would make the "one definition" claim in the new comment
(lines 113-117) literally true.

### IN-04: The reference stack still derives zero ordering edges

**File:** `test/src/core_test.mpconf:71-73`

The only real cross-component dependency, api-task → redis, is expressed as a hardcoded
`"redis://redis:6379"` via `WithContainerEnv` rather than through `WithRemoteOutput`, so
`dependencies(configs)` returns `[]` for all four configs and the generated
`terraform.yaml` has no `needs` between states. The new machinery is exercised only by
`handshake_test.mpconf`. This is acknowledged in that fixture's header, but it means the
production pipeline's apply order remains arbitrary for a dependency that is real.

### IN-05: Action versions are tag-pinned while the compiler is sha-pinned

**File:** `.github/workflows/drift.yaml:35`; `drivers/cicd/github_actions/src/github_actions.pinc:260, 280, 460, 466, 476, 530, 577, 622, 630`

`drift.yaml:37-40` argues at length that "an unverified download makes the thing that
decides 'is this output correct?' tamperable", then uses `actions/checkout@v4` — a mutable
tag — in the same job. The generated pipeline is the same throughout (`@v4`, `@v3`, `@v7`),
including `aws-actions/configure-aws-credentials@v4` on jobs holding the apply role. Pin to
commit SHAs, or drop the argument.

### IN-06: The local toolchain version is unpinned relative to CI

**File:** `.github/workflows/drift.yaml:32`, `test/Makefile`

CI pins `PROTOCONF_VERSION=0.2.0-rc2`; the compiler on this machine reports
`protoconf 0.0.1`. Nothing in the repo records or checks the expected compiler version
locally, so a contributor on a different build can produce output that CI's drift check
rejects — or, worse, accepts output CI would have generated differently. A one-line
`protoconf --version` assertion in `make test` would close it.

---

_Reviewed: 2026-09-08T01:05:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
