# Feature Research

**Domain:** Internal developer platform (IDP) / platform engineering — dependency-driven provisioning, cross-cutting policy, cost attribution
**Researched:** 2026-09-07
**Confidence:** MEDIUM (web search only, no `context7`/curated docs access in this environment; findings cross-checked across 2+ independent sources per tool where noted)

## Scope Note

This is a **subsequent milestone**. Existing platform (hook-chain component model, `WithDeps`/`ForDownstream`, `WithSLO` fan-out to Grafana, five Terraform backends, cross-state handshake, K8s rendering, derived CI ordering) is **not** re-researched. This file maps the four Active requirements in `PROJECT.md` — DB dependency fan-out, service-mesh authz from a declared edge, security-authored cross-cutting hooks, FinOps cost attribution — onto how Backstage, Crossplane, Score/Humanitec, KubeVela/OAM, and Radius solve the same problems, plus how platform teams typically express cross-cutting security policy and cost visibility.

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Stakeholder | Why Expected | Complexity | Notes |
|---------|-------------|---------------|------------|-------|
| Declare a dependency in the component/workload manifest, get it provisioned without hand-writing infra | Developer | Score's whole premise is "developers request resources their workload depends on declaratively"; Crossplane claims are consumed as "a simple YAML file"; Radius connections are declared in the app model. Already validated in this project via `WithDeps` — the fan-out is what's new. | LOW (mechanism exists) / MEDIUM (new drivers) | This project's `WithDeps`+`ForDownstream` is architecturally equivalent to Score's resource dependency + Radius's Connection — the gap is the driver behind it, not the declaration mechanism. |
| Credentials delivered to the workload without the developer touching a secret | Developer, Security | Crossplane compositions bind secrets with connection details into the claim; KubeVela's `service-binding` trait maps DB credentials into env vars; Humanitec's Resource Definitions select a driver per dependency type. Universal pattern. | MEDIUM | Already-validated project pattern ("credentials never in config; CI mints them") extends naturally — the DB driver needs to mint/deliver a credential the same way OIDC roles are minted today. |
| Dependency-scoped network access (only the declaring workload can reach the dependency) | Infra, Security | Every reviewed tool that provisions a database also scopes access to it (firewall rules, security groups) as part of the same composition — Crossplane's Azure SQL example provisions server + database + **firewall rules** together, not as an afterthought. | MEDIUM | Maps directly to Active requirement #1 ("network access rules... without naming any of them"). |
| Baseline security/hardening policy applied uniformly to a class of components, not hand-copied per component | Security | Kyverno and OPA Gatekeeper both exist specifically because "write the same guardrail into every manifest" doesn't scale; both are near-ubiquitous in Kubernetes platform-engineering stacks as the default answer to "cross-cutting policy." | MEDIUM | This project's answer (compose a hook into the chain via `Inherit`/`Finally`) is a **compile-time** alternative to Kyverno/Gatekeeper's **runtime admission** approach — see Differentiators. Either way, "policy applies to a selected subset without editing each subset member" is the non-negotiable capability. |
| Selector/label-based targeting of "all components matching X" for policy | Security, Infra | Gatekeeper's `Constraint` targets by kind/namespace/labelSelector; Kyverno's `match`/`exclude` blocks select by label. This is the standard shape platform teams reach for. | LOW–MEDIUM | Maps directly to Active requirement #2 ("component declarations carry enough shape... `all components with a public ingress`"). The component schema needs selector-able attributes (labels/tags/capability flags), not just a name. |
| mTLS and authorization between services that have declared a relationship | Security, Infra | Istio and Linkerd both provide automatic mTLS by default once meshed; Istio's `AuthorizationPolicy` is the standard mechanism for "only service X may call service Y." Radius explicitly frames this as "Radius automatically connects components... taking care of permissions." | MEDIUM–HIGH | Auto-mTLS is close to free (mesh-wide default). Auto-*authorization* (least-privilege allow-list) is not automatic in Istio/Linkerd out of the box — someone still writes the `AuthorizationPolicy`. That "someone" being the platform, derived from `WithDeps` edges, is the differentiating part (see below). |
| Cost visibility broken down by team/service/environment | FinOps, Infra | OpenCost/Kubecost's entire value proposition is mapping cloud billing to K8s objects via labels, broken out "by any label combination... environment, product line, or cost center." Described as the default FinOps starting point (showback) across every source reviewed. | LOW–MEDIUM | Requires nothing exotic: a consistent labeling/tagging convention emitted onto every generated resource. Showback (visibility) is table stakes; chargeback (financial enforcement) is not — see Anti-Features. |
| Fail loudly and early rather than silently misconfiguring a dependency | Developer, Infra | Universal expectation once a platform automates provisioning — a wrong or missing dependency should not silently produce a working-looking but broken resource. | LOW | Already a validated project principle ("fail at compile time... return `None` rather than a wrong answer"); extends unchanged to new drivers. |

### Differentiators (Competitive Advantage)

| Feature | Stakeholder | Value Proposition | Complexity | Notes |
|---------|-------------|--------------------|------------|-------|
| One dependency declaration fans out to network access + user/role provisioning + credential delivery + monitoring, all from a single edge, with no per-concern config | Developer, Infra, SRE, Security | No single reviewed tool does all four automatically from one declaration. Crossplane gives provisioning + secrets but not monitoring; Humanitec's Dynamic Configuration Management gets closest conceptually but is a commercial SaaS control plane, not a compile-time artifact. This project already proved the pattern once (SLO → Grafana); the differentiator is proving it generalizes to a *second*, structurally different fan-out (dependency → 4 concerns) rather than staying a one-off. | HIGH | This is the core thesis stated in `PROJECT.md`; the DB dependency is the proof-of-generalization, not just another feature. |
| Cross-cutting policy composed into the same compile-time hook chain that produces the Terraform, rather than a separate runtime admission webhook | Security, Infra | Kyverno/Gatekeeper enforce at admission time against a live API server — powerful but a *second* place policy can live, invisible in the generated artifact, and only catches what's applied to the cluster (not what's in source control). Composing security hooks the same way `WithSLO` composes monitoring keeps policy **in the compiled, inspectable Terraform**, consistent with the project's existing "output is data, not templates" principle. | MEDIUM–HIGH | Real tradeoff, not a strict win: compile-time hooks cannot catch a manual `kubectl apply` that bypasses the pipeline. Note for later PITFALLS research: whether a thin runtime admission layer is still needed as defense-in-depth, or whether "nothing applies outside the pipeline" is an enforced platform invariant. |
| Cost attribution derived from the same component declaration graph that drives provisioning and monitoring, not a bolted-on labeling policy applied after the fact | FinOps | Kubecost/OpenCost are effective only if labels are applied consistently — which is normally a separate governance effort (a "standard labeling plan," per FinOps sources). Emitting cost-attribution tags automatically wherever a component or dependency is declared removes that separate governance burden entirely. | LOW–MEDIUM | Cheapest differentiator to ship — mechanically similar to the existing failure-domain `Inherit` pattern, just propagating a cost-center/owner label instead. Good early/independent win. |
| All five stakeholders (developer, infra, SRE, security, FinOps) consume the *same* artifact, not five different views of a *shared model* | Developer, Infra, SRE, Security, FinOps | Backstage's catalog is a read-only index over manifests that live elsewhere — a second source of truth that can drift. Radius/KubeVela's application model *is* the source of truth for deployment but stops short of FinOps/security fan-out. This project's bet is that the component declaration is simultaneously the provisioning spec, the monitoring spec, the policy target, and the cost-attribution key. | Already the architecture | This is the "why" behind every other differentiator above, not a separate feature to build — worth stating explicitly in the roadmap as the thing every phase should reinforce. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|------------------|-------------|
| Backstage-style catalog UI (browsable service directory, TechDocs, plugin ecosystem) | Discoverability and ownership visibility feel like an obvious IDP checkbox item, and Backstage is the category-defining tool | Backstage's catalog is a *separate* index that must stay synced with reality — exactly the two-sources-of-truth problem this project's architecture exists to avoid. Building or adopting one recreates the drift risk `CONCERNS.md`-style issues already show up from (e.g. committed-but-stale outputs). | If a browsable view is wanted later, generate it *from* `materialized_config`/`outputs/` as a read-only render, never as an independently-edited store. |
| Runtime admission-webhook policy engine (Kyverno/Gatekeeper) as the *primary* security mechanism | It's the default, well-documented answer for "cross-cutting Kubernetes policy," so it's the first thing anyone with K8s experience reaches for | Duplicates the hook chain's job at a different layer and a different time (apply-time vs compile-time), creating two places a policy can be defined and two places it can drift apart. Violates the project's "output is data, inspectable" principle — an admission mutation never appears in the emitted Terraform/JSON. | Compose security hooks into the same Protoconf chain (`Inherit`/`Finally`), same mechanism as `WithSLO`. Revisit a *thin* admission layer only as defense-in-depth against changes that bypass the pipeline entirely — a decision for later, not a default. |
| Full chargeback (financial enforcement, billing-system integration) as the FinOps deliverable | "Real FinOps" sounds more complete than "just visibility" | FinOps community practice (per Kubecost/OpenCost sources) is explicit: run showback for ~90 days before introducing chargeback, because teams need to trust the numbers before they're held accountable to them. Billing integration is also org-specific plumbing, not a driver's concern. | Emit consistent cost-attribution labels/tags from the component declaration (showback). Leave chargeback/billing integration to the org's existing finance tooling, fed by those labels. |
| A single "service mesh" abstraction spanning two mesh vendors (e.g., Istio + Linkerd) behind one interface | Feels consistent with "one dependency type, one behavior" | Same union-of-neither trap the project already rejected for ECS vs. Kubernetes runtimes: an Istio `AuthorizationPolicy` and a Linkerd policy resource are shaped differently enough that a shared interface becomes the lowest common denominator of both. | One driver per mesh technology under `drivers/mesh/<name>/`, same structure as `drivers/runtime/`. |
| Open-ended/free-form dependency "kind" that lets a developer request arbitrary infrastructure (a generic Crossplane-style Composition escape hatch) | Maximum flexibility, avoids having to add a new driver for every new dependency type | Reopens exactly the problem the driver architecture solves: organization-specific values and untyped free-form config leaking into what's supposed to be the reusable half, and loses compile-time validation since an open-ended shape can't be a typed proto message. | Bounded dependency kinds (database, service, cache, queue, ...), each with its own driver and its own typed schema — same posture as today's one-driver-per-technology-choice rule. |

## Feature Dependencies

```
Component schema gains selector-able shape (labels/capability flags)
    └──requires──> [nothing new; extends existing platform.v1.Component]
                       └──enables──> Cross-cutting security hooks target "all components matching X"
                       └──enables──> FinOps cost-attribution labels emitted consistently

Database dependency fan-out
    └──requires──> Network-access-rule generation (needs component/dependency to expose enough shape to scope a rule)
    └──requires──> Credential delivery (reuses "credentials never in config, minted in CI" pattern already shipped)
    └──requires──> DB user/role provisioning driver (new; parallels state driver's per-backend structure)
    └──enhances──> Monitoring (a DB dependency should be able to contribute its own SLO/dashboard the way the component itself does)

Service-to-service dependency → mesh authorization
    └──requires──> WithDeps already declaring the edge (shipped)
    └──requires──> A mesh driver that turns an edge into an AuthorizationPolicy-shaped resource
    └──conflicts──> A single cross-mesh-vendor abstraction (anti-feature above)

Security-authored cross-cutting hooks
    └──requires──> Component schema selector-able shape (see above) — this is the prerequisite, not parallel work
    └──enhances──> Database and mesh fan-out (a security hook can compose onto the same chain those fan-outs use)

FinOps cost attribution
    └──requires──> Component schema selector-able shape (labels/cost-center) for consistent tagging
    └──independent of── database/mesh work; can ship earliest since it only needs labels, not new drivers
```

### Dependency Notes

- **Selector-able component shape is the true prerequisite**, not the DB or mesh drivers. Active requirement #2 in `PROJECT.md` ("component declarations carry enough shape") should land *before or alongside* the security-hooks requirement (#3) it's a precondition for — sequencing this after security hooks would mean building the targeting mechanism twice.
- **Database fan-out and mesh authorization are structurally parallel, not sequential** — both are "declare an edge, get a driver-specific consequence," reusing the same `WithDeps`/`ForDownstream` mechanism already proven by SLOs. They can be built independently once the prerequisite above lands, similar to how `runtime/kubernetes` and `runtime/ecs` are siblings.
- **FinOps cost attribution has the shallowest dependency chain** of the four target capabilities — it only needs the labeling/selector shape, no new driver category — making it the cheapest one to prove the pattern on first if a low-risk validation phase is wanted before the higher-complexity DB/mesh work.
- **Anti-feature conflicts:** a runtime admission-policy engine (Kyverno/Gatekeeper) conflicts with the compile-time security-hooks differentiator — pick one as the primary mechanism; do not build both as equally-weighted paths.

## MVP Definition

Not applicable in the startup sense (this is a subsequent milestone on a shipped platform), but ordered by "what proves the thesis generalizes, cheapest first":

### Land First

- [ ] Selector-able component shape (labels/capability flags on `platform.v1.Component`) — prerequisite for both cross-cutting security hooks and FinOps attribution; low complexity, no new driver
- [ ] FinOps cost-attribution labels emitted from the same declaration — cheapest full proof that "one declaration, another stakeholder's concern for free" generalizes beyond SLOs, with minimal new surface area

### Core of the Milestone

- [ ] Database dependency fan-out (network access + user/role provisioning + credentials + monitoring) — the requirement `PROJECT.md` names as the thesis-defining one
- [ ] Security-authored cross-cutting hooks applied via selectors — depends on the shape landed first

### Higher Risk / Sequence Later

- [ ] Service-to-service dependency → mesh authorization — needs a driver decision (which mesh, or driver-per-mesh from day one) and touches a technology (service mesh) not yet present anywhere in the stack, unlike DB/K8s which extend existing drivers

## Competitor Feature Analysis

| Feature | Crossplane | Score / Humanitec | Radius | This project's approach |
|---------|------------|--------------------|--------|--------------------------|
| Dependency declaration | Claim (namespaced CR) against a platform-defined XRD | Score file's `resources` block, resolved by Humanitec's Resource Definitions | `connections` in the app model | `WithDeps` hook marker (shipped) |
| Provisioning mechanism | Composition (Terraform/Bicep/Kubernetes-object templates behind the XRD) | Resource Definition selects a Driver per dependency type | Recipe (Terraform/Bicep template) per environment | New per-dependency-kind driver, same shape as `drivers/state`, `drivers/runtime` |
| Credential delivery | Composition writes a connection Secret | Driver returns outputs consumed as env vars/secrets | Recipe outputs wired into connection strings automatically | Extend "CI mints, never in config" pattern to DB credentials |
| Cross-cutting policy | Composition Functions / org-wide policy on Compositions (platform-team-owned, not per-claim) | Not primarily a policy tool | Not primarily a policy tool | Security hooks composed via `Inherit`/`Finally` targeting selector-matched components |
| Cost visibility | Not built in | Not built in | Not built in | Labels emitted from declaration, consumed by OpenCost/Kubecost-style tooling (not built by this project) |

## Sources

- [Claims · Crossplane v1.20](https://docs.crossplane.io/v1.20/concepts/claims/)
- [How to Implement Crossplane Compositions for Azure Database Provisioning](https://oneuptime.com/blog/post/2026-02-16-how-to-implement-crossplane-compositions-for-azure-database-provisioning/view)
- [How to Configure Crossplane Claims and XRDs](https://oneuptime.com/blog/post/2026-02-09-crossplane-claims-xrds-platform/view)
- [Self-Service Infrastructure with Crossplane: 2026 Guide](https://khimananda.com/blog/self-service-infrastructure-with-crossplane)
- [Master your Internal Developer Platform: Resource management theory | Humanitec](https://developer.humanitec.com/app-humanitec-io/guides/getting-started/master-your-internal-developer-platform/resource-management-theory/)
- [Resources: Overview | Humanitec](https://developer.humanitec.com/app-humanitec-io/docs/platform-orchestrator/resources/overview/)
- [Score: Examples | Humanitec](https://developer.humanitec.com/platform-orchestrator/docs/score/examples/)
- [How to deploy a Workload with Score and Humanitec | Humanitec](https://humanitec.com/blog/deploy-a-workload-with-score-and-humanitec)
- [Descriptor Format of Catalog Entities | Backstage](https://backstage.io/docs/features/software-catalog/descriptor-format/)
- [Day 184 — Understanding Relationships in Backstage](https://medium.com/@alokrahuldevops/day-184-understanding-relationships-in-backstage-how-entities-connect-inside-the-software-fb66f8948ef9)
- [GitHub - radius-project/radius](https://github.com/radius-project/radius)
- [Radius: A First Look | Codit](https://www.codit.eu/blog/radius-a-first-look/)
- [Microsoft's Radius and the future of cloud-native development | InfoWorld](https://www.infoworld.com/article/2335202/microsofts-radius-and-the-future-of-cloud-native-development.html)
- [Application | KubeVela — core concepts](https://kubevela.io/docs/getting-started/core-concept/)
- [OAM Definition Protocol | KubeVela](https://kubevela.io/docs/platform-engineers/oam/x-definition/)
- [Mutate Rules | Kyverno](https://kyverno.io/docs/policy-types/cluster-policy/mutate/)
- [Selecting Resources | Kyverno](https://kyverno.io/docs/policy-types/cluster-policy/match-exclude/)
- [[Feature] Select Mutate Targets using Label Selector · Issue #10407 · kyverno/kyverno](https://github.com/kyverno/kyverno/issues/10407)
- [OPA Gatekeeper: Policy and Governance for Kubernetes | Kubernetes.io](https://kubernetes.io/blog/2019/08/06/opa-gatekeeper-policy-and-governance-for-kubernetes/)
- [Kubernetes FinOps: Build Cost Ownership Into Engineering — CAST AI](https://cast.ai/blog/kubernetes-finops/)
- [Kubernetes Cost Allocation: Chargeback vs Showback — Plural](https://www.plural.sh/blog/kubernetes-cost-allocation-chargeback-showback/)
- [OpenCost: Kubernetes Namespace Showback and Chargeback](https://stribog.com/blog/opencost-namespace-showback-chargeback-kubernetes-finops)
- [Kubernetes Cost Visibility: OpenCost, Kubecost](https://cloudrps.com/blog/kubernetes-cost-visibility-opencost-kubecost/)
- [Istio Authorization Policies — dev.to](https://dev.to/maxineer/istio-authentication-authorization-35ji)

**Confidence caveat:** All findings sourced via general web search (no `context7`/curated-docs access available in this environment), several via secondary blogs rather than primary vendor docs. Primary-doc claims (Crossplane's own `docs.crossplane.io`, Humanitec's own `developer.humanitec.com`, KubeVela's own `kubevela.io`, Radius's own GitHub README) are rated MEDIUM-HIGH; secondary blog summaries are rated MEDIUM. Treat the specific mechanism names (e.g., exact trait names, exact Recipe syntax) as directionally correct, not verbatim API references — re-verify against primary docs at implementation time for any driver built against a specific tool's API.

---
*Feature research for: internal developer platform dependency-driven provisioning*
*Researched: 2026-09-07*
