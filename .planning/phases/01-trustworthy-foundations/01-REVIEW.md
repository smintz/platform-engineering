---
phase: 01-trustworthy-foundations
reviewed: 2026-09-08T10:35:00Z
depth: standard
scope: incremental (diff_base 8f7c9bb — plans 01-04 and 01-05)
files_reviewed: 4
files_reviewed_list:
  - src/platform/core.pinc
  - test/Makefile
  - test/src/handshake_test.mpconf
  - test/src/select_test.mpconf
findings:
  critical: 1
  warning: 3
  info: 5
  total: 9
status: issues_found
---

# Phase 01: Code Review Report (incremental)

**Reviewed:** 2026-09-08T10:35:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Incremental review of the gap-closure work since `8f7c9bb`: the `gates` target in
`test/Makefile`, the occurrence-preserving `SelectComponents` in
`src/platform/core.pinc`, and the two fixtures that assert them.

The two central claims were verified empirically, not read: in a throwaway git
worktree, deleting `_check_remote_backends(configs)` and
`_check_reads_are_produced(configs)` from `TerraformPipeline` makes `make gates`
fail with the correct diagnostic in both directions (both gates removed → FOUND-04
reported; only the reads check removed → FOUND-05 reported), and the log dump
confirms the design rationale for not asserting on exit code — the gate-less
FOUND-04 mutation exits non-zero from `_producers`' duplicate-state `fail()`, and
the gate-less FOUND-05 mutation exits non-zero from the fixture's own ordering
`fail()`. `make gates` passes on the unmodified tree. The message-plus-traceback
assertion is the right call and it works. The mutation/restore dance is also sound:
the tracked fixture is never written, only read.

That leaves the interaction the new `SelectComponents` contract creates with the
rest of the platform, which is where the one Critical lives: the selector now
deliberately hands back both live objects of a diamond, and `GetConfigs` —
directly below it in the same file — silently throws one of them away. Measured on
a diamond fixture: `occurrences=2`, `config_keys=["d/leaf/infra/main.tf.json"]`.
Everything else is diagnostic quality and cleanup robustness in the new Makefile
recipe.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: `GetConfigs` silently drops every same-keyed component but the last

**File:** `src/platform/core.pinc:265` (with `246-269`)

**Issue:** `configs[prefix + "/" + key] = cfg` keys on `"<domain>/<name>/<config
key>"`. `walk_upstreams` visits every occurrence, so the two distinct live objects
of a diamond both reach this line with the same key, and the second assignment
overwrites the first with no diagnostic. Which one survives is traversal order.

Measured, on a diamond built exactly like `select_test.mpconf`'s (leaf reached down
both `mid1` and `mid2`, leaf carrying a `WithState` config):

```
occurrences=2 config_keys=["d/leaf/infra/main.tf.json"]
```

This is pre-existing code, but the new contract is what makes it reachable and
makes it matter. `SelectComponents`' own comment (`215-231`) states the reason for
the change: *"a hardening hook or a cost centre applied across a selection has to
reach every live object"*. The platform now dutifully delivers that hook to both
live objects — and then renders only one of them. A hook that writes anything
arm-specific (a parent-derived tag, a per-arm allowlist, a cost centre taken from
the declaring component) produces two divergent configs at one key, and one of them
is discarded before the CI driver ever sees it. The driver cannot catch it either:
`_producers`' duplicate-state `fail()` only ever sees the survivor, so a component
whose Terraform config was dropped looks exactly like a component that was never
declared. Config declared and never applied is the failure mode the whole phase is
built to prevent, arrived at from the other side.

The repo already has the idiom for this — `_producers` fails on a duplicate state
id rather than overwriting.

**Fix:** Refuse to overwrite. Cheapest correct version, in `collect_configs`:

```python
            full_key = prefix + "/" + key
            existing = configs.get(full_key)
            if existing != None and str(existing) != str(cfg):
                fail(
                    ("GetConfigs: two components render different configs to %s — a " +
                     "component reached down two arms of the graph was mutated on one " +
                     "arm only, or two components share a domain and name. Rendering " +
                     "one of them would silently discard the other.") % full_key,
                )
            configs[full_key] = cfg
```

Failing only on *divergent* content keeps the benign diamond (two untouched, equal
leaves) compiling, which is what `handshake_test` and the reference stack rely on.
If uniqueness of `"<domain>/<name>"` is the intended platform invariant, assert it
unconditionally instead — but assert it somewhere, because right now nothing does.

## Warnings

### WR-01: The gates target's "check line N" guidance points at the wrong lines

**File:** `test/Makefile:39` and `test/Makefile:50`

**Issue:** Both substitution-did-not-land messages name a line number:

```
check that test/src/handshake_test.mpconf:64 still reads exactly 'NEAR_BACKEND = BACKEND'
check that test/src/handshake_test.mpconf:70 still reads exactly 'FAR_BACKEND = BACKEND'
```

The anchors are at lines **73** and **79**. Line 64 is `"us-east-1",` inside the
`MISMATCHED` backend and line 70 is `LOCAL = LocalBackend()`. This message is
printed in exactly one situation — a maintainer edited the fixture and broke an
anchor — and in that situation it sends them to two unrelated lines, one of which
(`LOCAL = ...`) is plausible enough to waste real time. The numbers were correct
against an earlier draft of the fixture and were not re-checked after it grew.

**Fix:** Drop the line numbers; the anchor text is already in the message and is
what `grep` actually looks for.

```make
		echo "gates: FOUND-04 substitution did not land in src/gate04_probe.mpconf — check that test/src/handshake_test.mpconf still contains a line reading exactly 'NEAR_BACKEND = BACKEND' (no trailing comment)"; \
```

### WR-02: Leftover probe files are not ignored and poison every later compile

**File:** `test/Makefile:36-37,48` (and the repo `.gitignore`)

**Issue:** The probes are written to `src/gate04_probe.mpconf` /
`src/gate05_probe.mpconf` and removed only by the `EXIT` trap. The trap covers
normal exits and ordinary failures, but not `SIGKILL`, a killed `make -j`, or a
crashed shell. Two consequences, both verified:

1. `protoconf compile .` — the second line of the `test` target — compiles
   everything under `src/`, so a surviving `gate04_probe.mpconf` turns the *next*
   `make test` red before it reaches anything the developer changed:
   `Error compiling config /gate04_probe.mpconf: error evaluating starlark file`.
   Nothing in that message says "stale artifact of an interrupted `make gates`".
2. Neither name is in `.gitignore`, so a leftover shows as `?? test/src/gate04_probe.mpconf`
   and `git add -A` will commit a fixture designed to fail the build.

The header comment's claim is narrower than it reads: the *tracked* fixture is
indeed never touched, but "nothing to restore" is only true of that file.

**Fix:** Belt and braces — clear stale probes at the start of the recipe, and
ignore them so an escapee can never be committed.

```make
gates:
	@set -e; \
	rm -f src/gate04_probe.mpconf src/gate05_probe.mpconf; \
	log=$$(mktemp); \
	...
```

```gitignore
# probes written by `make gates`, removed by its EXIT trap
test/src/gate*_probe.mpconf
```

### WR-03: The selection-mutation contract fails outright on a module-level graph, and nothing says so

**File:** `src/platform/core.pinc:215-240`, `test/src/select_test.mpconf:104-144`

**Issue:** The comment justifying the list return promises that a hook applied
across a selection reaches every live object. It does — but only while the graph is
still mutable. A graph held in a module-level global is frozen by the time `main()`
runs, and the promised use case dies on the first assignment. Verified:

```
Error compiling config zz_frozen.mpconf:
cannot set field of frozen message
  zz_frozen.mpconf:14:10: in main
```

`select_test.mpconf` builds its graph inside `main()` (`root = TopComponent().msg`,
line 105), so the fixture never meets this and the limitation is neither documented
nor tested. The first caller to write the natural thing — a component graph as a
module constant, selections applied in `main()` — gets `cannot set field of frozen
message` with no pointer to the cause, on the API whose entire documented purpose
is mutation through a selection.

**Fix:** One sentence on `SelectComponents`, where a caller will read it:

```python
# The objects returned are the live ones in the graph, so a caller can mutate through
# them — but only while the graph is mutable. A graph built at module level is frozen
# by the time main() runs and every write through a selection fails with "cannot set
# field of frozen message"; build the graph inside the function that mutates it.
```

## Info

### IN-01: "gate did not fire" is asserted for every non-matching compile outcome

**File:** `test/Makefile:43-47,54-58`

**Issue:** `protoconf compile ... || true` discards the exit status, so any failure
that is not the expected gate — a missing `protoconf` binary, an unrelated syntax
error in a loaded module, an unpopulated `.protoconf_cache` on a fresh clone —
prints the headline "FOUND-04 gate did not fire — `_check_remote_backends` did not
report a local backend", which is a specific and false claim. Observed on a fresh
worktree with no `.protoconf_cache`: that headline, followed by six
`try run protoconf mod sync` errors. The `cat "$log"` underneath makes the truth
recoverable, so this is a diagnostic-quality issue and not a correctness one.

**Fix:** Capture the status and distinguish the two cases, e.g.
`status=0; protoconf compile . gate04_probe.mpconf > "$$log" 2>&1 || status=$$?;`
then report "the probe did not compile at all" when the log matches neither the
gate message nor a Starlark `fail`.

### IN-02: The FOUND-04 probe is not isolated to the gate it names

**File:** `test/Makefile:37`, `test/src/handshake_test.mpconf:73`

**Issue:** Substituting `LOCAL` for `NEAR_BACKEND` leaves `FAR_BACKEND` pointed at
the s3 `BACKEND`, so the probe is simultaneously a valid FOUND-05 input (the
subscriber reads an s3 state nobody writes). It reports FOUND-04 only because
`_check_remote_backends` is called one line before `_check_reads_are_produced`
(`github_actions.pinc:670-671`). Reorder those two calls — something
`github_actions.pinc`'s own comment invites a future reader to think about — and
`make gates` reports "FOUND-04 gate did not fire" with both gates fully intact.
It fails safe, but on a false diagnosis.

**Fix:** Either note the dependency in the target's header comment next to the
existing ordering discussion, or accept the coupling explicitly by grepping the
FOUND-04 log for the absence of the FOUND-05 message too.

### IN-03: The two probe blocks are a copy-paste pair

**File:** `test/Makefile:37-47` and `test/Makefile:48-58`

**Issue:** Eleven lines duplicated with four substitutions (probe name, sed
expression, expected message, gate function). A third gate is a third copy, and the
stale line numbers in WR-01 are the kind of drift duplication produces — the same
mistake, twice, in two places that must be edited together.

**Fix:** One shell function taking `(probe, sed_expr, landed_pattern, message,
function, label)` and two calls, or a `for` loop over pipe-delimited tuples. Worth
doing at the third gate, not before.

### IN-04: `SelectComponents`' comment documents an implementation that no longer exists

**File:** `src/platform/core.pinc:224-229`

**Issue:** Six of the seventeen comment lines describe what the previous dict-based
collection did and why its collapse was non-idempotent. That reasoning is preserved
in the commit and in `select_test.mpconf:146-151`, which asserts the property. In
the source it is archaeology that a reader must first parse and then discard, and
it will read as a description of the current code to anyone skimming.

**Fix:** Keep the forward-looking half (every occurrence, why callers cannot survive
skipping, why a unique view is the caller's job) and drop the "the dict this used to
collect into" paragraph.

### IN-05: `make test` rewrites a tracked lock file with machine-absolute paths

**File:** `test/Makefile:2` (pre-existing line; adjacent to this diff, flagged
because `gates` now depends on the same flow)

**Issue:** `protoconf mod tidy` rewrites `test/protoconf.lock`, which is tracked and
contains `"getterUrl": "file:///Users/smintz/git/platform-engineering/..."`. Running
the suite from any other path dirties the file — observed immediately in the review
worktree (`M test/protoconf.lock`). In a repo whose other assertions are "an empty
`git diff` over generated output", a target that guarantees a non-empty diff on
every foreign checkout is a standing false positive.

**Fix:** Out of scope for this phase — either untrack the lock file or make the
`getterUrl` relative. Worth a backlog item rather than a fix here.

---

_Reviewed: 2026-09-08T10:35:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
