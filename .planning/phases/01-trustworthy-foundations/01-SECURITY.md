---
phase: "01"
slug: "trustworthy-foundations"
status: verified
# threats_open = count of OPEN threats at or above workflow.security_block_on severity (the blocking gate)
threats_open: 0
asvs_level: 1
created: "2026-09-08"
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

Built in State B from the `<threat_model>` blocks of all five PLAN files
(`register_authored_at_plan_time: true`) plus `01-04-SUMMARY.md`'s Threat Flags section.
ASVS L1, `security_block_on: high` — verification depth is grep-level, which L1 defines as
sufficient for a plan-time register.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| contributor PR → GitHub Actions runner | Untrusted, contributor-authored Starlark is executed by a compiler on a runner holding a repository token. | Starlark source; repository read token |
| GitHub release CDN → runner `/usr/local/bin` | An externally hosted binary becomes the thing that decides whether the build is "correct". | Compiler binary (tarball) |
| repository → public git history | Everything committed here is world-readable on a public repo. | Generated Terraform/workflow JSON, lockfile |
| declared component shape → policy selection | Labels declared by one author decide which hardening, cost and policy hooks a component receives in Phases 2 and 5. | `Component.Metadata.labels` |
| compiled config → Terraform state store | The compile-time backend decision determines which state a CI apply reads and writes, and whether it survives the job. | Terraform state (S3) |
| one Terraform state → another (cross-state read) | A `terraform_remote_state` read crosses a state boundary; orderability decides whether the apply sequence is correct or arbitrary. | Terraform outputs |
| ephemeral CI runner → persisted infrastructure | An apply runs on a runner whose disk is discarded when the job ends. | Terraform state, live cluster objects |
| contributor commit → the compile gates | The two compile gates are the only thing standing between a component and a state CI silently discards. | Starlark source |
| `make gates` → the working tree | A build target that writes into `test/src/` during a run, on a developer machine and on a runner. | Probe files |
| `SelectComponents`' returned list → the caller's mutation | Returned objects are live references into the graph; an omitted object is a component a hook never reaches. | Live `Component` references |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-01-01 | Elevation of Privilege | `drift.yaml` trigger block | high | mitigate | `on:` is `pull_request` / `push` / `workflow_dispatch` only; comment-filtered grep for the fork-context trigger returns 0 (UAT 9, 01-01/D3) | closed |
| T-01-02 | Elevation of Privilege | `drift.yaml` permissions block | high | mitigate | `permissions: contents: read` at :25-26 and nothing else; zero `id-token`, zero `secrets.` (UAT 9, 01-01/D3) | closed |
| T-01-03 | Tampering | protoconf binary download | high | mitigate | Pinned `PROTOCONF_VERSION: 0.2.0-rc2` + `PROTOCONF_SHA256: eeb8415960…`, verified by `sha256sum -c -` at :45 before extraction (UAT 9, 01-01/D3) | closed |
| T-01-04 | Tampering | `actions/checkout@v4` mutable tag | low | accept | Accepted for consistency with the repo's own generated pipeline — see Accepted Risks R-01 | closed |
| T-01-05 | Information Disclosure | `test/protoconf.lock` | low | accept | Unchanged by this phase; CI deletes its local copy — see Accepted Risks R-02 | closed |
| T-01-06 | Tampering | `SelectComponents` de-duplication | medium | mitigate → **superseded** | The dict-based de-duplication this entry specified was deliberately removed by 01-05 under D-11; `SelectComponents` is now `found = []` / `found.append(c)`. The residual risk (a non-idempotent hook running once per occurrence) is carried forward and accepted as T-01-S5 / R-06. Not silently closed — closed by an explicit later decision. | closed (superseded by T-01-S5) |
| T-01-07 | Tampering | `SelectComponents` completeness | medium | mitigate | One traversal (`walk_upstreams`) with two consumers, D-12 empty-golden-diff, and post-order/edge-case assertions in `select_test.mpconf` (UAT 12, 26, 29, 30, 31) | closed |
| T-01-08 | Information Disclosure | `Component.Metadata.labels` | low | accept | Free-form `map<string,string>`; credentials-never-in-config constraint held at the architecture level — see R-03 | closed |
| T-01-09 | Denial of Service | `walk_upstreams` recursion | low | accept | Component cycles are unconstructible (eager build from an uninstantiated factory); remote-state cycles caught by `_check_acyclic` — see R-04 | closed |
| T-01-10 | Tampering | redis Terraform state | high | mitigate | S3 backend rendered — `"bucket": "platform-engineering-tfstate"`, `"key": "us-east-1/redis.tfstate"`; recurrence made a compile error by `_check_remote_backends` (UAT 16, 17) | closed |
| T-01-11 | Tampering | `TerraformPipeline` apply ordering | high | mitigate | `_check_reads_are_produced(configs)` live at `github_actions.pinc:671`; fires on mismatch, silent on the correct pairing, and yields the sub→pub ordering edge (UAT 18, 19) | closed |
| T-01-12 | Denial of Service | `_check_reads_are_produced` strictness | medium | accept | No escape hatch, per locked D-17 — see R-05 | closed |
| T-01-13 | Tampering | first apply against the new redis S3 state | medium | transfer | Operational consequence of correcting the backend; transfers to whoever runs the first post-merge apply — see Operational Notes | closed |
| T-01-14 | Repudiation | driver prose vs driver behaviour | low | mitigate | Comment above `dependencies` rewritten to describe post-D-17 behaviour and name the trade; superseded text grep-confirmed gone (UAT 6, 01-03/D6) | closed |
| T-01-G1 | Tampering | gate call sites in `TerraformPipeline` | high | mitigate | `make gates` runs from `make test` (`test/Makefile:5`); replacing both calls with `pass` is now a red build printing `gates: … gate did not fire` (UAT 21, 22) | closed |
| T-01-G2 | Tampering | `MISMATCHED` / `LOCAL` constants | high | mitigate | Both are now live inputs to `make gates`, and `handshake_test.mpconf:42-70` says so — deleting them as dead code is now a red build (UAT 21, 25) | closed |
| T-01-G3 | Tampering | the `gates` assertions themselves | medium | mitigate | Verdict comes from the gate's message and the traceback function, never the exit code; each substitution is confirmed landed first (`substitution did not land`, ×2) (UAT 23) | closed |
| T-01-G4 | Denial of Service | probe files left in `test/src/` | low | accept | An interrupted run fails loudly on the residue rather than producing a wrong output — see R-07 | closed |
| T-01-G5 | Tampering | `test/Makefile` recipe neutering | medium | mitigate | Zero `-`-prefixed recipe lines; the only two `\|\| true` are on the `protoconf compile` lines that must capture a failing compile's output for assertion, not on any `grep` (UAT 23, 24) | closed |
| T-01-G6 | Repudiation | wrong function named in fixture comment | low | mitigate | Corrected against the measured traceback; fixture now names `make gates` and both gate functions (UAT 25) | closed |
| T-01-G7 | Elevation of Privilege | `drift.yaml` | low | transfer | Coverage arrives through the `make test` the workflow already runs — no new CI step, token scope or download; `drift.yaml` byte-identical (01-04/D5) | closed |
| T-01-S1 | Elevation of Privilege | `SelectComponents` | high | mitigate | Returns every occurrence in post-order; stamp-and-read-back assertion goes red on regression (UAT 26, 27) | closed |
| T-01-S2 | Repudiation | Phase 5 SEC-03 coverage artifact | high | mitigate | Same control — completeness of the returned set is the artifact's only input (UAT 26, 27) | closed |
| T-01-S3 | Tampering | returned list's object identity | high | mitigate | Read-back goes through `occurrences(root, [])` (3 refs), not through `SelectComponents`; `len(` count in the fixture is 0 (UAT 27) | closed |
| T-01-S4 | Tampering | `test/src/select_test.mpconf` | medium | mitigate | Mutation-falsification recorded: restoring the value-keyed dict makes the fixture red at `select_test.mpconf:111` (UAT 27) | closed |
| T-01-S5 | Information Disclosure | hook applied once per occurrence | low | accept | Deliberate — SEC-01 and COST-01 both want every occurrence reached; the alternative silently skips a component — see R-06 | closed |
| T-01-S6 | Spoofing | a `"<domain>/<name>"` uniqueness key | medium | mitigate | No such key exists in `SelectComponents`; `core.pinc:228` records why it is prohibited (D-11). The only `"<domain>/<name>"` keying in the file is `GetConfigs`' pre-existing config map at :265 | closed |
| T-01-SC | Tampering | package-manager installs | n/a | accept | No npm/PyPI/crates package is installed anywhere in this phase. The only external artifacts are the protoconf tarball (pinned by version + sha256) and `actions/checkout@v4`. Package Legitimacy Gate does not apply — no `[ASSUMED]`, `[SUS]` or `[SLOP]` verdict in RESEARCH.md | closed |

*Status: open · closed · open — below high threshold (non-blocking)*
*Severity: critical > high > medium > low — only open threats at or above workflow.security_block_on count toward threats_open*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| R-01 | T-01-04 | `actions/checkout@v4` is a moving major tag that could be repointed. Accepted for consistency with the pin the repo's own generated pipeline already uses at `github_actions.pinc:387`; a repo-wide move to SHA pins is a separate change. | 01-01-PLAN threat model | 2026-09-08 |
| R-02 | T-01-05 | `test/protoconf.lock` leaks a developer username and machine layout six times over. Unchanged by this phase — CI deletes its local copy rather than rewriting the committed one. Already recorded in Deferred. | 01-01-PLAN threat model | 2026-09-08 |
| R-03 | T-01-08 | `Component.Metadata.labels` is a free-form `map<string,string>`; an author could put a credential in it. A value-shape restriction is not expressible in the schema, `Component` itself is never materialized, and `ARCHITECTURE.md:218` already holds that credentials are minted in CI. | 01-02-PLAN threat model | 2026-09-08 |
| R-04 | T-01-09 | Unbounded `walk_upstreams` recursion on a cyclic graph. Not reachable: `Component` builds each dependency eagerly from an uninstantiated factory, so a component cycle cannot be constructed; remote-state cycles are caught by `_check_acyclic`. | 01-02-PLAN threat model | 2026-09-08 |
| R-05 | T-01-12 | `_check_reads_are_produced` has no escape hatch, so a component legitimately reading a state applied by another repository becomes an unfixable compile error. Accepted per locked D-17: nothing in the reference stack reads an external state, and a speculative hatch reintroduces the tolerance the check removes. | 01-03-PLAN threat model / orchestrator resolution | 2026-09-08 |
| R-06 | T-01-S5, **T-01-06** | A non-idempotent hook now runs twice on a component reached down two arms of a diamond, because `SelectComponents` returns every occurrence. This is the risk T-01-06 originally planned to mitigate by de-duplication; 01-05 reversed that under D-11 because the alternative silently skips a component, which is the worse failure. Recorded in `stated_assumptions`. | 01-05-PLAN threat model (D-11) | 2026-09-08 |
| R-07 | T-01-G4 | An interrupted `make gates` can leave a mutated probe copy in `test/src/`. The next `protoconf compile .` then fails loudly on it with the gate's own message — a red build a maintainer can read, never a silently wrong output. Accepted rather than defended with a lock file. | 01-04-PLAN threat model | 2026-09-08 |

---

## Operational Notes

**T-01-13 — first apply against the new redis S3 state (transferred).** The
`platform-engineering-tfstate` / `us-east-1/redis.tfstate` state starts empty. If a live
cluster already holds the redis Deployment and Service, the first post-merge apply will plan
to CREATE them. This is the intended consequence of correcting a backend that previously
discarded its state every run, not a code defect. Whoever runs that apply should either
import the existing objects into the new state or confirm the recreate is acceptable.

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-09-08 | 27 | 27 | 0 | /gsd-secure-phase (State B, L1, orchestrator grep verification) |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-09-08
