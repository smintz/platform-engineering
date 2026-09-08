# Requirements: Platform Engineering

**Defined:** 2026-09-07
**Core Value:** A product developer declares a dependency, and every other stakeholder's concern is applied automatically — without the developer knowing those concerns exist.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Foundation

<!-- The platform's own foundations must be trustworthy before four new fan-outs are built on them. -->

- [ ] **FOUND-01**: CI fails the build when committed generated output differs from a fresh `protoconf compile` of the source
- [ ] **FOUND-02**: A component carries declared key/value labels (`platform.v1.Component.Metadata.labels`) that describe its shape
- [x] **FOUND-03**: A platform author can select every component in a dependency graph matching a predicate, via an exported `SelectComponents`
- [x] **FOUND-04**: Compile fails with a message naming the fix when a component whose state CI will apply has no remote backend configured
- [x] **FOUND-05**: A cross-state value handshake authored by any driver is visible to CI apply-ordering derivation, or compile fails

### FinOps

<!-- Stakeholder: FinOps. Cheapest proof that the SLO fan-out generalizes to a new stakeholder. -->

- [ ] **COST-01**: An owner declares a cost center on a component and it propagates to every component in that component's dependency subtree
- [ ] **COST-02**: Every Terraform resource emitted by every driver carries the cost-attribution tags
- [ ] **COST-03**: Compile fails when a component emits billable resources but has no cost center attributed
- [ ] **COST-04**: A reviewer sees the estimated cost delta of a change on its pull request

### Database Dependency

<!-- Stakeholder: developer (declares), infra + security + monitoring (receive). The thesis-defining requirement. -->

- [ ] **DATA-01**: A developer adds a database dependency to a service component and the database role and its grants are provisioned
- [ ] **DATA-02**: The same declaration emits the network access rule permitting that service to reach that database, on both sides of the edge
- [ ] **DATA-03**: The service receives database credentials without any secret being written to Terraform state or to generated config
- [ ] **DATA-04**: The same declaration produces database monitoring without the developer declaring monitoring
- [ ] **DATA-05**: CI applies the database's state before the consuming service's state, with nobody declaring that order
- [ ] **DATA-06**: A `terraform apply` run by CI can reach the target database, with the network path an explicit documented decision rather than an assumption

### Service Mesh

<!-- Stakeholder: developer (declares), security + infra (receive). -->

- [ ] **MESH-01**: A developer declares a service-to-service dependency and access is granted for exactly that edge
- [ ] **MESH-02**: A service that declares no dependency on another service has no access to it

### Security Policy

<!-- Stakeholder: security. Depends on FOUND-02/03 and on real drivers populating tags. -->

- [ ] **SEC-01**: A security engineer authors a hardening hook that applies to every component matching a tag selector, without editing any of those components
- [ ] **SEC-02**: Compile fails when a policy's selector matches zero components
- [ ] **SEC-03**: A security engineer can see, from a generated artifact, exactly which components each policy applied to

## v2 Requirements

Deferred to a future milestone. Tracked but not in this roadmap.

### Service Mesh

- **MESH-03**: A component that needs mTLS or L7 authorization escalates from network policy to a full service mesh (Linkerd `Server`/`AuthorizationPolicy`)
- **MESH-04**: The mesh control plane is installed and versioned by the platform rather than out of band

### Database Dependency

- **DATA-07**: MySQL is supported alongside PostgreSQL
- **DATA-08**: Workloads that cannot use cloud-native IAM database auth receive credentials via an external secrets operator

### FinOps

- **COST-05**: Runtime (post-apply) cost allocation reported per team/service/environment from the tags the platform stamps
- **COST-06**: Cost budgets enforced rather than merely reported (chargeback), after a showback trust period

### Security Policy

- **SEC-04**: A runtime admission layer enforces policy as defense-in-depth against manifests applied outside the pipeline

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Backstage-style software catalog UI | Recreates the two-sources-of-truth problem this architecture exists to avoid — the component declaration is the catalog |
| Runtime admission policy (Kyverno/Gatekeeper) as the *primary* security mechanism | Duplicates the hook chain at a different layer and time, giving policy a second place to drift; the compiled artifact stays the single inspectable source. Deferred to v2 as defense-in-depth only |
| Chargeback (financial enforcement) before showback | FinOps practice is explicit that enforcing costs before tag coverage has earned trust destroys trust faster than no visibility at all |
| A single abstraction spanning two mesh vendors | Same union-of-neither trap already rejected for ECS vs Kubernetes — one driver per mesh |
| An untyped, open-ended "dependency kind" escape hatch | Reopens exactly what the per-driver architecture exists to prevent |
| Istio as the mesh escalation path | Heaviest CRD and operational surface of the options; worst fit for a lean per-edge driver |
| Crossplane-style in-cluster reconcilers | A second execution engine alongside Terraform; the platform has no runtime controller by design |
| Drift detection against out-of-band infrastructure changes | Accepted tradeoff of the compile-time-only model — the platform emits configuration, Terraform reconciles it |
| Readiness gating ("is the database actually up") | The platform derives apply *ordering*, not runtime health; that is a monitoring concern |
| Application runtime or service hosting | This platform emits configuration; it does not run services |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUND-01 | Phase 1 | Gaps Found |
| FOUND-02 | Phase 1 | Gaps Found |
| FOUND-03 | Phase 1 | Complete |
| FOUND-04 | Phase 1 | Complete |
| FOUND-05 | Phase 1 | Complete |
| COST-01 | Phase 2 | Pending |
| COST-02 | Phase 2 | Pending |
| COST-03 | Phase 2 | Pending |
| COST-04 | Phase 2 | Pending |
| DATA-01 | Phase 3 | Pending |
| DATA-02 | Phase 3 | Pending |
| DATA-03 | Phase 3 | Pending |
| DATA-04 | Phase 3 | Pending |
| DATA-05 | Phase 3 | Pending |
| DATA-06 | Phase 3 | Pending |
| MESH-01 | Phase 4 | Pending |
| MESH-02 | Phase 4 | Pending |
| SEC-01 | Phase 5 | Pending |
| SEC-02 | Phase 5 | Pending |
| SEC-03 | Phase 5 | Pending |

**Coverage:**

- v1 requirements: 20 total
- Mapped to phases: 20
- Unmapped: 0 ✓

---
*Requirements defined: 2026-09-07*
*Last updated: 2026-09-07 after roadmap creation — 20/20 v1 requirements mapped to 5 phases*
