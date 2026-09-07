# Project Research Summary

**Project:** Platform Engineering — Protoconf/Starlark → Terraform JSON internal developer platform
**Domain:** Internal developer platform (IDP) / declarative platform engineering — compile-time hook-chain over a component model, no runtime controller
**Researched:** 2026-09-07
**Confidence:** MEDIUM-HIGH

## Executive Summary

This is a subsequent milestone on a working platform whose thesis is already proven once: an SRE adds `WithSLO(...)` to a component and Grafana dashboards appear downstream, with no dashboard hand-written. The milestone's job is to prove that same fan-out mechanism (`WithDeps`/`ForDownstream`, `Inherit`) generalizes to four new stakeholders — database provisioning, service-mesh authorization, security-authored cross-cutting policy, and FinOps cost attribution. All four researchers independently converge on the mechanism: reuse `WithRemoteOutput`'s near/far hook-pair pattern for two-sided fan-out (DB, mesh), reuse `Inherit` for ambient tags (cost), and add exactly one new primitive — a `tags` field on `Component` plus an exported `SelectComponents` selector — for shape-based policy targeting. No new marker kind, no new core abstraction, no runtime controller is needed anywhere; every driver is new leaf code plus one small, additive proto field.

The recommended stack extends rather than replaces what's shipped: `cyrilgdn/postgresql`/`petoju/mysql` for DB role/grant provisioning, IRSA + native cloud IAM auth as the default credential path (no secret ever created), `kubernetes_network_policy_v1` (zero new provider) as the default service-access mechanism with Linkerd as an opt-in escalation, and Infracost (pre-apply, CI-native) + OpenCost (runtime allocation) for FinOps — both operating on the compiled artifact this platform already produces. The clearest anti-patterns to avoid: Crossplane-style in-cluster reconcilers (a second execution engine), runtime admission-webhook policy (Kyverno/Gatekeeper) as the *primary* security mechanism (a second, driftable place policy lives), and chargeback before showback has earned trust.

The dominant risk is not any single new driver — it's that this codebase's own foundations are not yet trustworthy enough to build four fan-outs on top of. CI applies committed, possibly-stale generated Terraform rather than a fresh compile; there is zero schema-level validation; and a hook that writes into a second Terraform state outside `WithRemoteOutput` is already known to break CI apply ordering (the documented redis→api-task gap). Every one of the four new drivers reproduces one or more of these exact failure classes if built directly on the current foundation, and DB credential handling is a genuinely new, sharper risk (a password that Terraform's normal resource model wants to persist to state, unlike anything the platform stores today). The research is split on *whether* to fix this before building features or prove features first and fix foundations in parallel — this summary resolves that disagreement explicitly below rather than picking one researcher's framing silently.

## Key Findings

### Recommended Stack

New Terraform providers this milestone: `hashicorp/aws` (~6.63.x, not yet wired despite a vendored v5 IAM-only proto stub), `cyrilgdn/postgresql` (1.27.0), `petoju/mysql` (3.0.9, only if MySQL actually appears), `hashicorp/helm` (3.1.0, for one-time control-plane installs only — Linkerd, ESO, OpenCost). Everything else needed is already in the vendored `hashicorp/kubernetes` 3.2.1 provider (`kubernetes_network_policy_v1`, `kubernetes_manifest` for mesh CRDs).

**Core technologies:**
- `cyrilgdn/postgresql` / `petoju/mysql` — DB role/grant/database provisioning as ordinary Terraform resources, same shape as everything else this platform emits
- IRSA (IAM role for K8s ServiceAccount via OIDC) + RDS/cloud-native IAM database auth — credential delivery with **zero secret ever created**, extending the existing "credentials never in config" constraint to databases; ESO is the documented fallback only for workloads that can't do IAM-token auth
- `kubernetes_network_policy_v1` — default, zero-new-dependency mechanism for "declared edge → network access rule"; Linkerd (`Server`/`AuthorizationPolicy` CRDs via `kubernetes_manifest`, control plane via one `helm_release`) is the opt-in escalation for mTLS/L7, explicitly *not* Istio (heaviest CRD surface, worst fit for a lean per-edge driver)
- Infracost (pre-apply CI cost diff, reads the compiled `.tf.json` directly) + OpenCost (free, CNCF, runtime allocation reading the tags the cost-attribution hook stamps) — no new Terraform state, no commercial tier (Kubecost) needed yet

### Expected Features

**Must have (table stakes):** declare a dependency, get it provisioned without hand-writing infra (already the `WithDeps` shape); credentials delivered without the developer touching a secret; dependency-scoped network access alongside provisioning, not bolted on after; baseline hardening applied uniformly to a class of components without hand-copying; selector/label-based targeting of "all components matching X"; cost visibility broken down by team/service/environment; fail loudly at compile time, never silently misconfigure.

**Should have (differentiators):** one dependency declaration fanning out to network access + provisioning + credentials + monitoring from a single edge with no per-concern config (no competitor tool does all four automatically); cross-cutting policy composed into the same compile-time hook chain rather than a separate runtime admission layer (keeps policy in the inspectable, compiled artifact); cost attribution derived from the same declaration graph that drives provisioning/monitoring, not a bolted-on labeling governance effort; all five stakeholders consuming the *same* artifact as the single source of truth (this is the "why" behind every other differentiator).

**Defer / anti-features — do not build:** a Backstage-style catalog UI (recreates the two-sources-of-truth problem this architecture exists to avoid); Kyverno/Gatekeeper-style runtime admission policy as the *primary* mechanism (duplicates the hook chain at a different layer/time — a thin admission layer is a legitimate *later* defense-in-depth decision, not a default); full chargeback (financial enforcement) before a showback trust period; a single abstraction spanning two mesh vendors (recreates the ECS/K8s union-of-neither trap already rejected in this project); an open-ended, untyped "dependency kind" escape hatch (reopens exactly what the driver architecture exists to prevent).

### Architecture Approach

Every declarative system surveyed (Crossplane, KubeVela/OAM, Score, Terraform module composition, Kyverno/Gatekeeper) solves two-sided dependency fan-out the same structural way this codebase already solves it in `WithRemoteOutput`: one factory returns two hooks closing over shared state — a provider-side hook and a `ForDownstream`-wrapped consumer-side hook — with ordering guaranteed by construction (`Component()` always finishes building a dependency, including its full hook chain, before firing `RunForDownstream`). Cross-cutting policy is solved differently everywhere it's solved well: never inlined into the thing it targets, but separated into a selector (a cheap, declared field — a label or `type`) plus a separately-authored action, exactly Kyverno's `match` block / OAM's `policy` concept. This codebase has no such field today; that's the one real schema gap.

**Major components (all additive, no core-plumbing rewrite):**
1. `platform.v1.Component.tags` (new proto field, `map<string,string>`) — the only thing cross-cutting policy is allowed to test against; never unpack `configs`/Terraform internals to infer shape
2. `SelectComponents(root, predicate)` (new, exported from `core.pinc`, built by factoring out the existing private `walk_upstreams`) — walks the same tree `GetConfigs` already proves correct, returns matching components for a second policy pass
3. `drivers/database/<engine>/` and `drivers/mesh/<name>/` (new driver modules) — near/far hook pairs reusing `WithDeps`/`ForDownstream`/`Inherit` exactly as `WithRemoteOutput` does, zero core change beyond `tags`
4. `WithCostCenter(...)` (new, `Inherit`-wrapped) — structurally identical to the existing `WithFailureDomain`, fits the current marker system precisely
5. A policy library (e.g. `src/platform/policy.pinc`) — a loop over `SelectComponents` results calling already-exported `chain`/`mutate_config`; explicitly **not** a fifth marker kind

Explicit compile-time-only limits to carry into the roadmap, not hide: no drift detection against out-of-band changes, no true readiness gating (only apply *ordering*, not "is the DB actually up"), no dynamic re-evaluation across separate compiles, no self-healing. These are accepted tradeoffs of the "no runtime controller" constraint, not gaps to close.

### Critical Pitfalls

1. **DB credentials landing in Terraform state** — the natural Terraform-native way to create a DB user (`random_password` → resource argument) persists the password in state plaintext forever; this is a materially different problem than the CI-minted, short-lived tokens the platform already handles. Avoid via IRSA/cloud-native IAM DB auth (no secret exists) or Terraform `ephemeral` values/dynamic-secrets as fallback — never a plain resource argument.
2. **Cross-state writes that bypass `WithRemoteOutput`** — a hook that writes into a second state directly (not via the publisher/dependant pair) is invisible to this platform's CI-apply-ordering derivation, which is recovered purely from backend-key ↔ `terraform_remote_state` matching. This exact failure already exists undetected today (redis→api-task, per CONCERNS.md) and every new two-sided driver (DB, mesh, security) is a fresh chance to reproduce it.
3. **Cross-cutting policy that silently matches nothing (or everything)** — with zero schema validation and no compile-time "matched N components" assertion, a selector bug is undetectable by construction; nobody can audit which components a security hook actually touched. Needs a typed selector plus a compile-time match-count check and a generated coverage artifact.
4. **Compile/apply drift** — CI already applies committed `test/outputs/` rather than a fresh `protoconf compile`, so a source change without a local `make -C test` yields a green build against stale Terraform. Every new driver adds more generated surface that can independently go stale. The single fix (`git diff --exit-code` after a fresh compile, as a CI check) is cheap and closes the gap for all four new drivers at once, which is why it belongs early rather than being fixed four times.
5. **Cost attribution built on unenforced tag coverage** — a cost hook wired into only the newest driver silently undercounts; showback before chargeback is the correct sequencing per FinOps practice, and requires the field be compile-time-required, not opt-in.

## Implications for Roadmap

### Where the four researchers disagreed on ordering, and how this resolves it

All four proposed a build order; they converge on mechanism but diverge on **what goes first**:

- **Architecture** proposes: cost attribution → `tags`/`SelectComponents` schema → DB driver → mesh driver → security policy. Rationale: cheapest-proves-the-pattern-first, and policy is meaningless until something populates `tags`.
- **Features** proposes largely the same shape (selector-able shape + cost attribution first, as the "shallowest dependency chain"), but explicitly flags mesh as highest-sequencing-risk because it's the one technology (service mesh) not present anywhere in the stack yet.
- **Pitfalls** proposes a **foundation phase first** — compile/apply drift check, schema validation groundwork — because every subsequent phase (cost, DB, mesh, security) inherits the same unchecked-drift and unchecked-cross-state-write risk, and retrofitting after several drivers copy a bad pattern is "a security incident, not a refactor." This is not a feature phase at all; it's explicitly named in `PROJECT.md`'s own Active requirements ("the platform's own foundations are trustworthy enough to build these on").
- **Stack** doesn't propose a full phase order but flags the NetworkPolicy-based mesh-access driver as lowest-risk to build (zero new provider dependency) and the database driver as **highest operational risk**, specifically because Terraform-runner-to-database network reachability (can a GitHub-hosted CI runner even reach a private RDS instance?) is an infrastructure question that can silently block `terraform apply` on this driver alone, unlike every other new provider (AWS, Kubernetes, Grafana, Helm) which only calls a control-plane API. Stack recommends this be resolved with an explicit spike, not discovered at the first failed apply.

**Reconciliation, and why:** Architecture and Features are right that cost attribution and the `tags`/`SelectComponents` schema are the cheapest, lowest-risk proof points and should land early. But Pitfalls is right that "early" is not the same as "first" — a foundation phase that closes the compile/apply drift gap is *cheaper than it looks* (one CI step: compile, then `git diff --exit-code` against committed output) and every phase after it, including the cheap cost-attribution one, silently inherits the drift risk if skipped. Since Pitfall 4 (drift) and the `tags` schema addition are both small, low-risk, mechanical changes with no interdependency between them, they can be sequenced together as one foundation phase rather than sequential phases — this reconciles Pitfalls' "foundation first" position with Architecture/Features' "cheap wins first" position without picking one over the other. Stack's DB-reachability risk is real and independent of ordering — it is called out below as a spike to run *before* (or in parallel with, if capacity allows) the DB driver phase, not as a reason to reorder the whole roadmap; the network-path question is a decision each org's own CI/VPC topology answers, no earlier available research resolves it generically.

### Phase 1: Foundation — close compile/apply drift, add `Component.tags` + `SelectComponents`
**Rationale:** Pitfall 4 (drift) is inherited by every later phase if left open; `tags`/`SelectComponents` is a small additive schema change that unblocks policy and cost work and has zero downside to landing early. Bundling them avoids a separate "foundation" phase feeling like pure overhead — this phase also ships the first visible capability (selector-able components).
**Delivers:** CI step that fails the build on any diff between fresh `protoconf compile` output and committed `test/outputs/`/`test/materialized_config/`/copied workflow; `platform.v1.Component.tags` proto field; exported `SelectComponents` built from the existing `walk_upstreams`.
**Addresses:** Foundation requirement in `PROJECT.md` Active list; prerequisite for Features' "selector-able shape" requirement.
**Avoids:** Pitfall 4 (compile/apply drift) directly; sets up the schema needed to avoid Pitfall 3 (silent policy mismatch) later.

### Phase 2: FinOps cost attribution (`WithCostCenter`)
**Rationale:** Cheapest full proof that "one declaration, another stakeholder's concern for free" generalizes beyond SLOs — fits the existing `Inherit` marker exactly, no new driver category, no new provider. Independent of DB/mesh work.
**Delivers:** `Inherit`-wrapped hook stamping cost/owner tags onto every resource-emitting driver's output; Infracost wired into the CI pipeline as a PR cost-diff step.
**Uses:** Infracost CLI (reads compiled `.tf.json` directly, no new state).
**Avoids:** Pitfall 5 (untrusted cost numbers) — ship as showback only, and require the attribution field at compile time rather than as opt-in, with coverage checked across every resource-emitting driver before calling this "done."

### Phase 3: Database dependency spike — CI-runner-to-DB network reachability
**Rationale:** Stack's flagged highest-operational-risk item, independent of the driver's business logic: before writing the `cyrilgdn/postgresql`/`petoju/mysql` driver, confirm the CI runner topology can actually reach the database (VPC path, self-hosted runner, or bastion/SSM tunnel) — a decision that must be made explicitly, not discovered at the first failed `terraform apply`.
**Delivers:** A documented network-path decision and, if needed, the CI runner change (self-hosted runner in-VPC, or tunnel step) to support it.
**Research flag:** This phase needs org-specific infrastructure research (VPC layout, existing runner topology) not resolvable from external sources — flag for `--research-phase` or a live investigation, not desk research.

### Phase 4: Database dependency driver (full fan-out)
**Rationale:** The requirement `PROJECT.md`'s Active list leads with; generalizes `WithRemoteOutput`'s near/far pair into a second real use; the first driver to populate `tags["datastore"]`. Sequenced after the network-path spike (Phase 3) resolves the sharpest unknown.
**Delivers:** `drivers/database/<engine>/` — near hook provisions DB role/grant + security-group ingress on the DB side; far hook (via `ForDownstream`) writes the consumer-side network-access rule and credential reference; credential delivery via IRSA/cloud-native IAM DB auth (no secret in state).
**Implements:** Architecture's two-sided hook-pair pattern; Stack's IRSA + RDS-IAM-auth recommendation.
**Avoids:** Pitfall 1 (credentials in state) — this is the pitfall's own stated "must be resolved architecturally before the first DB driver merges" moment; Pitfall 2 (cross-state writes bypassing `WithRemoteOutput`) — every cross-state write in this driver must go through the sanctioned publisher/dependant mechanism.

### Phase 5: Service mesh authorization driver
**Rationale:** Independent of the DB driver once the near/far-pair convention is validated by Phase 4; can run in parallel with it given two contributors, sequential otherwise. Lower infrastructure risk than the DB driver (default mechanism needs zero new provider) but touches a technology (service mesh) genuinely new to the stack if escalating past `NetworkPolicy`.
**Delivers:** Default `kubernetes_network_policy_v1`-based access-rule driver from any declared `WithDeps` edge (no new provider); optional escalation path to Linkerd `Server`/`AuthorizationPolicy` CRDs for components that need mTLS/L7 authorization, installed once via a new `hashicorp/helm` control-plane driver.
**Uses:** `kubernetes_network_policy_v1` (existing provider), Linkerd 2.20 CRDs + `hashicorp/helm` 3.1.0 (new, escalation only).
**Avoids:** Pitfall 2 (cross-state writes) — the mesh grant must be expressed as a `WithRemoteOutput` pair if it crosses states, not a bare second `configs[]` write.

### Phase 6: Security-authored cross-cutting hooks
**Rationale:** Sequenced last on purpose (Architecture, Features, and Pitfalls all agree here) — needs `tags` (Phase 1) *and* needs at least one driver actually populating meaningful tags (Phase 4/5) or there's nothing real to select against. Also the phase where an unaudited/silently-empty selector is the sharpest risk, so it benefits most from Phase 1's foundation work already being in place.
**Delivers:** A policy library (e.g. `src/platform/policy.pinc`) applying hardening hooks to `SelectComponents`-matched components; a compile-time match-count assertion and a generated "policy X applied to components [...]" coverage report.
**Addresses:** Features' table-stakes "baseline security policy applied uniformly" and "selector/label-based targeting" requirements.
**Avoids:** Pitfall 3 (silent policy mismatch / unauditable coverage) directly — this is the pitfall's named prevention phase.

### Phase Ordering Rationale

- Foundation (drift + schema) first because it's small, mechanical, and every later phase inherits its risk if skipped — this is the one place this summary overrides a "cheapest wins first" ordering with a "cheapest-that-also-de-risks-everything-else" ordering.
- Cost attribution next because it is genuinely independent of DB/mesh and validates the fan-out thesis a second time with minimal surface area, per Architecture and Features.
- The DB driver gets its own preceding spike phase specifically because Stack identifies a category of risk (network reachability) that no other new driver in this milestone shares — every other new provider only calls a control-plane API.
- Mesh and DB are structurally parallel (both "declare an edge, get a driver-specific consequence" via the same hook-pair mechanism) — order between them is a resourcing decision, not a dependency; DB is placed first here only because `PROJECT.md` names it as the thesis-defining requirement, not because mesh depends on it.
- Security policy is last because it is the one phase whose *purpose* (selecting components by shape) is unimplementable without `tags` already being populated by real drivers — this is the one hard sequencing dependency all four researchers agree on.

### Research Flags

Needs deeper research during planning:
- **Phase 3 (DB network-reachability spike):** org-specific VPC/CI-runner topology, not resolvable from external sources — needs live investigation of the actual GitHub Actions runner environment and database network placement.
- **Phase 4 (DB driver):** credential-delivery mechanism specifics (ephemeral resources vs. dynamic secrets vs. IRSA-only) should be re-verified against current Terraform/AWS provider version behavior at implementation time — Stack notes provider version pins should be re-checked, not assumed.
- **Phase 5 (mesh driver), Linkerd escalation path:** CRD schema specifics (`Server`/`AuthorizationPolicy`) should be verified against the exact Linkerd version pinned at implementation time; service-mesh comparison research here was MEDIUM confidence (cross-checked blogs, no single authoritative benchmark).

Phases with standard, well-documented patterns (skip deep research-phase):
- **Phase 1 (foundation):** the drift-check CI step and `tags` schema addition are direct extensions of patterns already proven in this codebase (`GetConfigs`, `chain`/`mutate_config`).
- **Phase 2 (cost attribution):** directly parallels the already-shipped `WithFailureDomain` pattern; Infracost's CI integration is documented and operates on an artifact this platform already produces.
- **Phase 6 (security hooks):** mechanism is fully specified by the Architecture research (selector + `SelectComponents` + ordinary hook reapplication); the remaining work is policy content, not new plumbing.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | Provider/tool identity and versions verified against official registries (HIGH); service-mesh "best fit" judgment and FinOps tagging-hook design are synthesized/inferred (MEDIUM) |
| Features | MEDIUM | Web search only, no curated-docs access; cross-checked across 2+ sources per claim, but several via secondary blogs rather than primary vendor docs |
| Architecture | MEDIUM | Findings cross-checked against each project's own docs (Crossplane, KubeVela, Score, Kyverno/Gatekeeper) but sourced via general web search; this repo's own architecture claims (read directly from source) are HIGH confidence |
| Pitfalls | HIGH for this-repo claims / MEDIUM for general domain claims | Codebase-specific failure modes read directly from `CONCERNS.md`/`ARCHITECTURE.md` (HIGH); general platform-engineering pitfall patterns corroborated across multiple current sources but no single canonical spec (MEDIUM) |

**Overall confidence:** MEDIUM-HIGH — the mechanism (extend `WithDeps`/`ForDownstream`/`Inherit`, add `tags`+`SelectComponents`) is convergently supported by all four researchers reading independent external systems and this repo's own source; specific version pins and exact ordering priorities are the parts most likely to need re-verification at implementation time.

### Gaps to Address

- **DB-runner network reachability** (Stack's flagged highest-risk item) is org-specific and unresolved by any research file — addressed above as an explicit Phase 3 spike rather than left implicit.
- **Foundation-first vs. features-first ordering disagreement** between Pitfalls and Architecture/Features — resolved above by bundling the cheap parts of both into one early phase rather than a full sequential foundation phase; if the org has stronger time pressure, Phase 1's drift-check-only sliver could ship alone with `tags` deferred to just before Phase 6, but that reintroduces exactly the risk Pitfalls warns about (drivers built without validation getting a second full pass later).
- **Terraform `ephemeral` value support** for DB credentials — Pitfalls research flags this as a *possible* mechanism (Terraform 1.10+) but this stack is pinned to 1.9.8; confirm at Phase 4 planning time whether an upgrade is in scope or whether cloud-native dynamic secrets (Vault, Secrets Manager rotation) is the only available path.
- **State-locking gap** (S3 backend with no `dynamodb_table`/`use_lockfile`) is flagged by Pitfalls as a pre-existing issue that every new state this milestone adds inherits — not one of the four Active requirements, but worth flagging to whoever scopes Phase 1, since it compounds with Pitfall 2 (cross-state races) once four new drivers add new states.

## Sources

### Primary (HIGH confidence)
- This repo: `.planning/codebase/STACK.md`, `.planning/codebase/ARCHITECTURE.md`, `.planning/codebase/CONCERNS.md`, `.planning/PROJECT.md`, `src/platform/core.pinc`, `src/platform/platform.pinc`, `drivers/state/terraform/src/terraform.pinc`
- Terraform Registry: `cyrilgdn/postgresql`, `petoju/mysql`, `hashicorp/aws`, `hashicorp/helm`, `hashicorp/vault` provider docs
- AWS Database Blog — RDS/Aurora Postgres IAM authentication
- Linkerd official release page
- HashiCorp Terraform docs — managing sensitive data in configuration
- Crossplane, KubeVela, Score official docs (docs.crossplane.io, kubevela.io, docs.score.dev)
- Kyverno / OPA Gatekeeper official docs

### Secondary (MEDIUM confidence)
- Service-mesh comparison synthesis (Istio/Linkerd/Cilium) — multiple independent 2026 comparison articles
- Infracost vs. OpenCost vs. Kubecost positioning — multiple cross-checked comparisons
- FinOps Foundation Framework, CloudZero, usage.ai — showback vs. chargeback guidance
- Firefly, GitGuardian — Terraform secrets management best practices
- Backstage, Radius, Humanitec/Score competitor-feature blog sources

### Tertiary (LOW confidence)
- None flagged — all findings were at least cross-checked across 2+ independent sources or read directly from primary docs/this repo.

---
*Research completed: 2026-09-07*
*Ready for roadmap: yes*
