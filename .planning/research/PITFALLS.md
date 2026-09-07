# Pitfalls Research

**Domain:** Internal developer platform — compile-time config-as-code (Protoconf/Starlark) generating Terraform + CI, fanning a single component declaration out to security, provisioning, mesh, and cost concerns
**Researched:** 2026-09-07
**Confidence:** HIGH (architecture/codebase claims — read directly from this repo's own analysis docs); MEDIUM (general platform-engineering domain claims — corroborated by multiple current sources, no single canonical spec)

This file focuses on the four milestone extensions named in scope — DB-as-dependency with credential delivery, service-mesh authorization from declared edges, security-authored cross-cutting hooks, and FinOps cost attribution — plus the structural risks this codebase's own architecture (hook chain, multi-state topology, compile-then-apply split) creates for all four.

## Critical Pitfalls

### Pitfall 1: DB credentials land in Terraform state or generated JSON because "create a DB user" is a resource, not a hook

**What goes wrong:**
The natural Terraform-native way to provision a database user is a resource block (`aws_db_instance` master password, `postgresql_role`, `mysql_user`) whose password argument is a plain string attribute. Once that argument is set from a Starlark-generated value — even a "random-looking" one — Terraform persists it in plan files and in state, in plaintext, by default. Anyone with read access to the state backend (S3 bucket, GCS bucket, Terraform Cloud org) reads the password. Marking a Terraform *output* `sensitive = true` only hides it from CLI output; it is still in state.

**Why it happens:**
This project's own stated constraint is "credentials never in config; CI mints them" (`.planning/PROJECT.md` Constraints, and already proven for OIDC roles and Grafana service-account tokens in `drivers/cicd/github_actions/src/github/lib.pinc`). But that pattern was built for *CI-minted, short-lived, delivery-only* credentials (a token handed to a job and thrown away). Database user provisioning is a different shape of problem: something has to durably create the DB role/user and its password *once*, generally at apply time, and Terraform's normal resource model wants to own that value and therefore stores it. It is easy to reach for `random_password` + a DB provider resource because it "looks like everything else this stack already does," without noticing that this one, unlike OIDC/token minting, has no CI-only escape from state.

**How to avoid:**
- Provision the *role and its permission grants* declaratively (safe — no secret material), but generate/rotate the *credential itself* through a mechanism that never writes it to Terraform state: cloud-native dynamic secrets (Vault's `database` secrets engine, AWS Secrets Manager rotation Lambda, IAM database auth where the cloud supports it) so the running value is minted per-consumer and expires.
- If Terraform 1.10+'s `ephemeral` resources/values are usable in this stack's provider set, they exist precisely for this: fetched at plan/apply time, used, never persisted to state or plan files.
- Credential *delivery* to the workload should follow the same "CI mints, workload receives at runtime" shape already proven for Grafana tokens — not a Terraform output wired into a Kubernetes Secret manifest that then sits in `materialized_config/`.
- Whatever mechanism is chosen, it must be a hook contributed by the state/DB driver, not something a component author does ad hoc per service — otherwise you get inconsistent handling per team, which is the multi-tenant version of the same failure.

**Warning signs:**
- Any `.tf.json` output in `outputs/` or `materialized_config/` containing a field like `password`, `master_password`, or a `random_password` resource whose result feeds directly into a DB resource's password argument.
- A PR that adds DB user provisioning by copying the shape of an existing Terraform resource block rather than the CI-minting pattern used for OIDC/Grafana tokens.
- No `sensitive = true` and no ephemeral/dynamic-secret provider anywhere in the new driver's diff.

**Phase to address:**
Whichever phase adds the database dependency driver (the "DB dependency fans out to its full consequence set" Active requirement). This must be resolved architecturally before the first DB driver merges — retrofitting credential handling after several drivers copy the bad pattern is a security incident, not a refactor.

---

### Pitfall 2: One component declaration silently writes into more than one Terraform state, defeating the state topology this codebase already relies on

**What goes wrong:**
This codebase's existing invariant is "one state per config key," with infra and monitoring deliberately separated (`src/platform/monitoring.pinc`, noted as a "Pending" but load-bearing Key Decision in PROJECT.md: *"a dashboard change should not be able to touch a Deployment"*). A DB-dependency hook, a mesh-authorization hook, or a security cross-cutting hook that writes both to the dependant's `infra` state *and* to a shared "security" or "mesh" state in the same hook invocation reintroduces exactly the coupling the split was designed to prevent: an apply of one concern can now touch resources that conceptually belong to a different owner. Worse, if the new state key isn't wired into the CI driver's `terraform_remote_state`-based ordering (see Pitfall 5's sibling problem), two states writing overlapping resources can race, and Terraform has no cross-state locking — a corrupted or half-applied resource is the result.
More subtly: this project derives apply order purely from `terraform_remote_state` edges recovered from backend-URI matching (`_backend_state_id` / `_remote_state_id` in `drivers/cicd/github_actions/src/github_actions.pinc`). A hook that writes a resource into two states without expressing that write as a `WithRemoteOutput`/`terraform_remote_state` pair is *invisible to the ordering algorithm* — the two applies get no relative order at all. This is not hypothetical here: CONCERNS.md already documents this exact failure for `redis`→`api-task` ("No CI ordering for non-state dependencies" — a `ForDownstream` + literal env var, not a remote-state read, gives the two `infra` applies no ordering).

**Why it happens:**
Cross-cutting concerns (mesh authorization touching both a service's own state and a mesh-control-plane state; a security hook touching both a resource's IAM and a central audit-log state) naturally want to write "here's my grant" in one place and "here's the registration" in another. The hook-chain model makes this trivially expressible in Starlark — nothing stops a hook from calling both `Terraform()` config APIs against two different `configs[]` map keys in one function body. Nothing in the type system enforces "a hook only touches the state key(s) its caller expects."

**How to avoid:**
- Every hook that writes to a *second* state must do so through the existing sanctioned mechanism (`WithRemoteOutput`'s publisher/dependant pair), never through a raw second `Terraform()` mutation — that is what makes the write visible to the CI ordering derivation.
- Add a compile-time validator (the codebase has zero right now — see Pitfall 5 and CONCERNS.md "No validators anywhere") that asserts: any config key a hook contributes to must be declared as either the component's own state or reached via a remote-state edge, never a bare third key.
- When designing the mesh-authorization and security hooks, decide up front which state owns the "grant" resource (usually: the *authorizing* side's state, referenced by the *authorized* side via remote output) and hold that boundary as a rule, the same way infra/monitoring is held as a rule today.

**Warning signs:**
- A new driver's hook function body contains more than one `configs[...]` assignment to different domain/name keys without a `WithRemoteOutput` pair between them.
- Terraform plan output shows a resource in `mesh/main.tf.json` that also appears (or is referenced without a `data "terraform_remote_state"` block) in a service's own `infra/main.tf.json`.
- The generated GitHub Actions workflow shows two jobs for related states with no `needs:` edge between them, the same signature CONCERNS.md already flags for redis→api-task.

**Phase to address:**
The phase introducing the mesh-authorization driver and the phase introducing security cross-cutting hooks — both are explicitly two-sided writes (authorizer + authorized, or policy source + every matched component) and are the highest-risk introductions of this pattern. Fix the ordering/validator gap (see Pitfall 5) before or alongside these, not after.

---

### Pitfall 3: Security/cross-cutting hooks silently fail to match their intended targets, and nobody can audit which components a policy actually touched

**What goes wrong:**
The Active requirement "component declarations carry enough shape for cross-cutting policy to select the right targets" is, in every policy-engine ecosystem, the single most common source of a false sense of security: a selector (label match, type match, `WithDeps` inspection) that is *supposed* to match "all components with a public ingress" instead matches nothing, or matches everything, and the compile succeeds either way because nothing asserts the match set is non-empty or bounded. In Kubernetes policy engines (OPA/Gatekeeper being the closest analogue), this exact failure mode is well documented: a `ConstraintTemplate`'s violation rules only fire for resource kinds explicitly listed in the constraint's `match` block, so a typo or an omitted kind means the policy is "installed" but evaluates against nothing — and a Rego (or here, Starlark) rule can evaluate to "undefined" rather than "false," which is not the same as "denied." There is no runtime alerting for a policy that quietly matches zero components.
The second half of the failure is auditability: because this platform's hooks are ordinary functions composed at compile time with no logging (CONCERNS.md: "Logging: None in Starlark; `protoconf compile` output only"), there is no record, after the fact, of *which* hooks fired on *which* component, or which security hook a given resource's presence is attributable to. If a security team asks "which services currently have hardening hook X applied," the only honest answer today is "read every `.mpconf` file and every driver a component's chain transitively loads" — there is no queryable inventory.

**Why it happens:**
The hook-chain model's strength — a hook doesn't need to know about the components it will run against — is exactly what makes "did this hook run on the right set" unverifiable by construction. A selector bug is silent because there is no independent check of "expected match count" or "expected match count changed since last compile." This project has zero schema-level validation today (CONCERNS.md), so there is no place cross-field policy intent ("every component with a datastore dependency must carry hook X") is even expressible, let alone checked.

**How to avoid:**
- Do not let "matching" be implicit (a hook that inspects `component.upstreams` ad hoc). Give security-authored cross-cutting policy an explicit, typed selector (e.g., a proto-typed predicate over `Component` fields) and a **compile-time validator** — this project's stated failure mode is "fail at compile time... return `None` rather than a wrong answer" (PROJECT.md Constraints) — that asserts the selector's match set is non-empty (or explicitly allow-listed as legitimately zero) and prints the matched component list as part of the build.
- Emit the match result as a build artifact: a generated manifest (JSON or even just compile-time output) listing "policy X applied to components [...]" per compile, so a security review has something to diff against. This does not need a runtime system — `protoconf compile` already produces `materialized_config/`; a policy-coverage report is the same kind of derived artifact.
- Treat "which hooks ran on this component" as a first-class question the compiler can answer, not something inferred by reading Starlark source.

**Warning signs:**
- A cross-cutting hook is merged and the PR shows no diff in any component's `outputs/` — meaning it matched nothing, and nobody checked.
- Security review process is "grep the driver source," not "read a generated report."
- A selector uses field presence (`component.HasField(...)`) on the undocumented, still-TODO field noted in CONCERNS.md (`src/platform/v1/platform.proto:68`, `TODO(smintz): Fill this out`) — building policy selection on an unspecified field compounds two unresolved problems into one.

**Phase to address:**
The phase introducing security-authored cross-cutting hooks, and it should be sequenced *after* (or bundled with) a phase that adds schema-level validation generally — CONCERNS.md already names this as a foundation gap ("Zero schema-level validation... all cross-field enforcement is ad-hoc `fail()` inside drivers"), and PROJECT.md's own Active requirements list "the platform's own foundations are trustworthy enough to build these on" as a prerequisite. Building policy selection before validators exist means the first policy hook is also the first validator, written under feature pressure rather than as infrastructure.

---

### Pitfall 4: Compile-time-generated artifacts drift from what CI actually applies — already true in this repo, and every new fan-out hook adds another way for it to happen

**What goes wrong (already present here):**
CONCERNS.md documents this directly: *"CI never runs `protoconf compile` — it plans and applies the committed `test/outputs/`, so a source edit without `make -C test` yields a green build against stale generated Terraform"* ("No CI job compiles the protoconf sources"). This is the canonical GitOps drift failure — the same failure the "rendered manifests pattern" in the ArgoCD/GitOps world exists specifically to close (render in CI, never trust a manually- or locally-generated artifact) — except here it's not even drift between two automated stages, it's a manual `make -C test` step whose output *is* the thing CI applies. A contributor who edits `src/platform/core.pinc` or a driver and forgets to run `make -C test` (or whose `make` fails silently and leaves stale files) gets a green CI run that plans and applies whatever was last committed to `test/outputs/`, regardless of what the source now says.
Two more instances of the same shape already exist: the generated workflow is installed by `cp` into `.github/workflows/` with no drift check (CONCERNS.md, "Generated workflow installed by file copy" — a change to `OUTPUT_ROOT` without regenerating the copy makes the workflow point at nothing, *silently*, since the `paths:` trigger filter just stops matching); and stale generated trees are checked in at the repo root describing a component (`aurora-user-api-task`) that no longer exists in any source file, with no way to tell which of two output trees is authoritative (CONCERNS.md, "Stale generated artifacts checked in at the repo root").

**Why it happens:**
The project's own architecture is compile-then-apply with the compiled artifact committed to git rather than produced fresh per CI run. That's a legitimate choice (inspectable diffs, no compiler-in-the-critical-path-of-apply) — but it only holds its guarantee if CI enforces "committed output == fresh compile output" on every change. Nothing currently does. Every new driver (DB provisioning, mesh authorization, security hooks, cost attribution) adds more generated surface area that can independently go stale, and — because "hook ordering is load-bearing and undocumented outside comments" (CONCERNS.md) — a hook reordering in one driver can silently change another driver's output with no error, just wrong committed state that then doesn't match a future recompile.

**How to avoid:**
- Add the single CI check CONCERNS.md itself proposes: after `protoconf compile`, run `git diff --exit-code test/outputs test/materialized_config` (and the same for the copied `.github/workflows/terraform.yaml`) and fail the build if the committed tree disagrees with a fresh compile. This is the direct analogue of the GitOps "rendered manifests" pattern's CI-based rendering check, adapted to a compile-and-commit workflow instead of a render-on-merge workflow.
- Delete the stale, unreachable output trees at the repo root now, before more drivers add to the ambiguity of "which tree is real."
- Any new driver's Makefile/CI wiring should compile as part of the pipeline that also plans/applies — not trust a human to have run `make` locally first.

**Warning signs:**
- A PR that touches `src/` or `drivers/` without a corresponding diff in `test/outputs/` or `test/materialized_config/`.
- CI green on a source-only change with zero generated-file diff.
- Two output trees for the same component, or an output tree for a component absent from any `.mpconf`.

**Phase to address:**
This is foundation work, not feature work — PROJECT.md's own Active requirements list it explicitly ("the platform's own foundations are trustworthy enough to build these on... missing backends a compile error rather than silent local state"). It should be an early phase in this milestone, before or in parallel with the first new driver, precisely because every subsequent phase (DB provisioning, mesh, security hooks, cost attribution) adds more generated surface that inherits the same unchecked-drift risk if the CI gap is left open.

---

### Pitfall 5: FinOps cost attribution ships numbers nobody trusts, because it's built on tag/label coverage the platform doesn't yet enforce

**What goes wrong:**
Cost attribution derived from component declarations is only as good as the coverage and consistency of whatever the platform emits as cost-allocation tags (component slug, team owner, environment, failure domain). Current FinOps practice is explicit about the ordering mistake to avoid: rushing to chargeback (billing teams for their actual usage) before the underlying tag/allocation data is trustworthy generates budget disputes that "erode trust in FinOps" faster than having no cost visibility at all, and chargeback-grade tagging maturity is a materially higher bar (industry guidance cites ~90%+ consistent tag coverage) than the "directional visibility" bar showback needs. In this codebase specifically, that coverage cannot be assumed: the existing `WithFailureDomain` pattern is `Inherit`-wrapped ambient context (PROJECT.md: "Ambient context inheritance... (failure domain today)"), meaning a component that doesn't explicitly opt in, or whose upstream chain has a gap, can end up with an unset or wrong attribution field — and with zero schema-level validation in the codebase today (CONCERNS.md), there is nothing that would catch a missing cost-tag at compile time versus discovering it three months later as an "unattributed spend" line item nobody can explain.
A second, more architecture-specific risk: because every driver renders its own Terraform resources independently (state, monitoring, runtime, mesh, DB), a cost-attribution hook needs to reach *every* resource-emitting driver consistently, or the attributed total will silently undercount (resources from drivers the cost hook doesn't yet cover) in a way that's invisible until someone reconciles against the actual cloud bill.

**Why it happens:**
Cost attribution is usually bolted on last, after the resource-emitting drivers already exist, so it inherits whatever tagging discipline (or lack of it) those drivers happened to have — and unlike a security policy that fails loudly (a missing IAM grant breaks something), a missing cost tag fails silently (the spend still happens, it's just unattributed) and the failure isn't visible until a monthly bill reconciliation.

**How to avoid:**
- Make the cost-attribution tag/label a required field of the same `Component` schema, enforced by a compile-time validator (once validators exist — see Pitfall 3), not an opt-in hook a driver author might forget to call.
- Start with showback (visibility only, no chargeback consequence) until the platform can demonstrate tag coverage across every resource-emitting driver — this matches current FinOps guidance and avoids the "billing dispute during rollout" failure mode.
- Reconcile derived attribution against actual cloud billing data periodically and treat a gap as a bug in a specific driver, not noise.

**Warning signs:**
- A cost-attribution PR that adds a hook to one or two drivers (e.g., runtime) but not others (state, monitoring, mesh) — the total will be structurally wrong even if each covered driver is correct.
- No compile-time enforcement that a component carries the attribution field — meaning coverage silently degrades as new components/drivers are added.
- Chargeback discussed before a showback period has established that stakeholders trust the numbers.

**Phase to address:**
The FinOps phase, sequenced *last* among the milestone's new drivers (after DB provisioning, mesh, and security hooks exist) so the cost-attribution hook has real resource-emitting drivers to cover and can be validated against them — sequencing it first would mean building attribution against a moving, incomplete set of resource types.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|--------------------|-----------------|------------------|
| DB password as a plain Terraform resource argument instead of dynamic-secrets/ephemeral | Ships in an afternoon, looks like every other resource in the stack | Plaintext credential in every state backup, every `terraform show`, every state-reader's blast radius | Never — this is the one thing PROJECT.md's own security constraint already forbids |
| A cross-cutting hook writes to a second state directly instead of via `WithRemoteOutput` | Fewer lines, no publisher/dependant plumbing | Invisible to CI apply ordering (already true for redis→api-task); races on shared resources | Never for hooks that write real resources; acceptable only for read-only lookups that don't need ordering |
| Selector-based policy hook ships without a "matched N components" compile-time assertion | No new validator infrastructure needed | A typo'd selector silently matches zero (or all) components and nobody notices until an incident | Acceptable only for a throwaway spike never merged to the driver used by real components |
| Cost-attribution hook added to the newest/most-active driver only | Fast to demo | Systematically undercounts everything from older drivers; erodes trust before chargeback even starts | Acceptable for a showback prototype explicitly labeled partial-coverage, never for anything billed |
| Trusting `make -C test` was run locally instead of a CI compile-and-diff check | No CI runtime, no new workflow step | Exactly the drift CONCERNS.md already documents — silently stale applies | Never past a solo-prototype stage |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|------------------|-------------------|
| Database provider (RDS/Cloud SQL/etc.) resource for user/role creation | Password argument fed straight from `random_password`, landing in state | Provision role/grants declaratively; mint the credential via Vault dynamic secrets, cloud Secrets Manager rotation, or Terraform `ephemeral` values so it never touches state |
| Service mesh authorization policy (e.g., an `AuthorizationPolicy`-shaped resource) | Written into the *authorized* service's own state as a side effect of a `ForDownstream` hook, with no remote-state edge back to the authorizing service | Treat the grant as a `WithRemoteOutput` publisher/dependant pair like existing cross-state values, so CI ordering and auditability both see it |
| Security hardening hook applied via `Inherit` | Assumed to propagate to every downstream because it's `Inherit`-wrapped, without checking whether every component actually roots through the failure-domain chain that carries it | Verify propagation with the same compile-time "matched components" report proposed in Pitfall 3, not by reading the hook's source and assuming |
| Cost/billing tag source of truth | Derived independently in the cost-attribution driver from ad hoc component fields, diverging from whatever tags the cloud provider's billing export actually keys on | Use the exact tag keys the cloud billing export groups by, sourced from one place in the schema, not re-derived per driver |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|-----------------|
| Every cross-cutting hook re-walks the full upstream graph per component | Compile time grows superlinearly as component count grows | Cache/memoize per-component derived views the way `GetConfigs`'s depth-first walk already does once per component, not once per hook | Noticeable past a few dozen components; this repo's own `Walk` bug (CONCERNS.md — iterates the wrong field) shows how easy it is to get graph traversal wrong when writing it a second time instead of reusing `GetConfigs` |
| One monolithic generated GitHub Actions workflow, fully unrolled per state | Already flagged in CONCERNS.md: 4 states → 9 jobs today; a DB, mesh, and security state each add more | Matrix strategy or one workflow per failure domain before this milestone's new drivers push the count into the dozens | CONCERNS.md already names "a few dozen states" as the threshold where this becomes unreviewable and risks GitHub's job-per-workflow limits |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| DB credential in Terraform state (Pitfall 1) | Anyone with state-backend read access reads a live DB password | Dynamic secrets / ephemeral values; never a plain resource argument |
| Cross-cutting security hook with no compile-time proof of what it matched (Pitfall 3) | A hardening policy silently applies to zero components; security team believes coverage exists that doesn't | Compile-time match-count validator + generated coverage report |
| Mesh authorization grant declared without expressing the state-crossing explicitly (Pitfall 2) | Two applies of related mesh/service resources race with no lock and no order, corrupting one silently | Route every cross-state write through `WithRemoteOutput`, never a bare second config-key assignment |
| S3 state backend with no locking, already true in this repo (CONCERNS.md: `S3Backend` emits only `bucket`/`key`/`region`, no `dynamodb_table`/`use_lockfile`/`encrypt`) | Two refs applying concurrently corrupt state silently — and every new driver adds another state that inherits this same unlocked backend | Add locking/encryption to `S3Backend` before, not after, this milestone multiplies the number of states that need it |
| Grafana token cleanup step deletes tokens by string-sorted `expiresAt` comparison with `|| true` swallowing failures (CONCERNS.md) | Timezone/format drift leaks live tokens or deletes valid ones; a security-hooks phase that mints its own tokens the same way inherits the identical bug | Delete only tokens this workflow run named (`gha-$GITHUB_RUN_ID-...`), not a heuristic scan — fix before copying the pattern into new drivers |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-------------------|
| A product developer declares a DB dependency and gets a compile-time `fail()` with no actionable message when a required argument (e.g., which credential-delivery mechanism) is missing | Developer can't self-serve; files a ticket to the platform team, defeating the whole "derive without the developer knowing" premise | Follow the project's own stated failure mode — "fail at compile time... with a message naming the fix" — for every new driver, not just the ones that already do it |
| Escape hatch for mesh/security policy doesn't exist, so a team with a legitimate edge case works around the platform entirely (e.g., hand-writes Terraform outside the generated tree) | Untracked, unaudited resources that the platform's own cost/security fan-out never sees | Design a governed escape hatch (explicit opt-out hook with required justification/owner field) alongside the golden path, per current IDP guidance on the golden-path/golden-cage tradeoff |
| Cost numbers shown to a team before tag coverage is proven trustworthy | Team disputes the number, ignores all future reports from the same source | Ship showback only, explicitly labeled partial/beta, until coverage is measured across every resource-emitting driver |

## "Looks Done But Isn't" Checklist

- [ ] **DB dependency driver:** Often missing "no plaintext credential in state" verification — check every generated `.tf.json` for a DB resource whose password argument traces to a literal or a `random_password` resource rather than an ephemeral/external secrets reference.
- [ ] **Mesh authorization hook:** Often missing CI apply ordering — check the generated workflow for a `needs:` edge between the authorizing and authorized service's jobs, the same check that would have caught the existing redis→api-task ordering gap (CONCERNS.md).
- [ ] **Security cross-cutting hook:** Often missing proof of match scope — check that compiling produces some artifact listing which components it touched, not just "it compiled without error."
- [ ] **Cost attribution:** Often missing full driver coverage — check that the attribution hook is wired into every resource-emitting driver (runtime, state, monitoring, mesh, DB), not just the one most recently touched.
- [ ] **Any new driver's generated output:** Often missing a CI compile-and-diff check — verify `test/outputs/`/`test/materialized_config/` actually match a fresh `protoconf compile`, not just that the last commit "looks right."
- [ ] **Any new backend/state introduced by a new driver:** Often missing a non-local-backend compile-time check — verify it inherits whatever fix closes the existing `redis/infra` silent-local-backend bug (CONCERNS.md), rather than being a fresh instance of the same gap.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|-----------------|------------------|
| Credential already leaked into committed/remote state | HIGH | Rotate the credential immediately at the database, treat the old state file as compromised, purge sensitive values from state history (`terraform state rm` + re-import, or backend-level history purge), migrate to dynamic secrets before re-provisioning |
| Cross-state write shipped without ordering, causing a race-corrupted apply | MEDIUM | Identify the two states from the plan/apply logs, manually re-apply in the correct order once, then retrofit the `WithRemoteOutput` pair so it can't recur |
| Security hook shipped with a silently-empty match set | LOW–MEDIUM | Add the missing match-count assertion, recompile, diff the newly-matched components' `outputs/`, and treat every newly-appearing resource as "was never actually protected" for incident-review purposes |
| Cost attribution numbers already distrusted after a premature chargeback rollout | HIGH (organizational, not technical) | Roll back to showback-only, publish the specific coverage gap that caused the dispute, re-earn trust over a full billing cycle before re-attempting chargeback |
| Generated artifacts already diverged from source (the existing `aurora-user-api-task` orphan) | LOW | `git rm -r` the unreachable output tree, add the compile-and-diff CI check so it can't recur, treat any future divergence as a build failure, not a manual cleanup |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|--------------------|---------------|
| DB credentials in state (Pitfall 1) | DB-dependency driver phase | Grep every generated `.tf.json` for password-shaped fields; confirm none trace to a literal or plain resource attribute |
| Cross-state writes without ordering (Pitfall 2) | DB-dependency, mesh-authorization, and security-hook phases (each introduces new cross-state writes) | Generated workflow has a `needs:` edge for every pair of states one hook writes into |
| Silent policy mismatch / unauditable policy (Pitfall 3) | Foundation phase (schema validation) before or alongside the security-hooks phase | Compile emits a per-policy matched-component report; a deliberately-broken selector fails the build, not just "compiles clean" |
| Compile/apply drift (Pitfall 4) | Foundation phase, early in this milestone, before the first new driver | CI job runs `protoconf compile` and fails on any diff against committed `outputs/`/`materialized_config/`/copied workflow |
| Untrusted cost numbers (Pitfall 5) | FinOps phase, sequenced last | Attribution total reconciled against actual cloud billing export within an acceptable variance before chargeback (not just showback) is proposed |

## Sources

- [Manage sensitive data in your configuration — HashiCorp Terraform docs](https://developer.hashicorp.com/terraform/language/manage-sensitive-data) — HIGH confidence (vendor docs)
- [Secret Management in Terraform: Protecting State Files — Firefly](https://www.firefly.ai/academy/secret-management-in-terraform-keeping-sensitive-data-out-of-state-files) — MEDIUM confidence (vendor blog, cross-checked against HashiCorp docs)
- [Terraform Secrets Management Best Practices — GitGuardian](https://blog.gitguardian.com/terraform-secrets-management/) — MEDIUM confidence
- [Golden cage syndrome: Why 80% of Internal Developer Platforms fail — platformengineering.org](https://platformengineering.org/blog/golden-cage-syndrome-why-internal-developer-platforms-fail) — MEDIUM confidence (community publication specific to this domain)
- [Golden Paths in IDPs — Pulumi Blog](https://www.pulumi.com/blog/golden-paths-infrastructure-components-and-templates/) — MEDIUM confidence (vendor blog)
- [Audit — Gatekeeper official docs](https://open-policy-agent.github.io/gatekeeper/website/docs/audit/) — HIGH confidence (project docs)
- [Audit gatekeeper evaluation base seems to not match — open-policy-agent/gatekeeper#1883](https://github.com/open-policy-agent/gatekeeper/issues/1883) — MEDIUM confidence (issue tracker, real-world instance of the failure mode)
- [Showback vs Chargeback: How to Choose Your Allocation Model — usage.ai](https://www.usage.ai/blogs/finops/governance/showback-vs-chargeback/) — MEDIUM confidence
- [Chargeback vs. Showback: Cloud Cost Allocation Models Explained — CloudZero](https://www.cloudzero.com/blog/chargeback-vs-showback/) — MEDIUM confidence (cross-checked against usage.ai and finops.org framework)
- [Invoicing & Chargeback — FinOps Foundation Framework](https://www.finops.org/framework/capabilities/invoicing-chargeback/) — HIGH confidence (industry-body framework docs)
- [The Rendered Manifests Pattern — Akuity](https://akuity.io/blog/the-rendered-manifests-pattern) — MEDIUM confidence (vendor blog, describes the same compile/apply drift class this repo already exhibits)
- [Cross-state reads, without the whole state — stategraph.com](https://stategraph.com/blog/solving-terraform-remote-state) — MEDIUM confidence
- `.planning/codebase/CONCERNS.md` (this repo) — HIGH confidence, primary source for every "already present in this codebase" claim
- `.planning/codebase/ARCHITECTURE.md` and `.planning/PROJECT.md` (this repo) — HIGH confidence, primary source for architectural constraints and stated invariants

---
*Pitfalls research for: internal developer platform / config-as-code fan-out (Protoconf → Terraform + CI)*
*Researched: 2026-09-07*
