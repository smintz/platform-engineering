# Stack Research

**Domain:** Internal developer platform — declarative service components fanning out to DB
provisioning, service mesh, security hooks, and FinOps (Terraform-JSON-emitting, Protoconf/Starlark authored)
**Researched:** 2026-09-07
**Confidence:** HIGH for provider/tool identity and versions (official registries, cross-checked); MEDIUM for
service-mesh "best declarative fit" judgment (synthesized from multiple 2026 comparison sources, no single
authoritative benchmark); MEDIUM for FinOps tagging-hook design (pattern inference from existing codebase, not
an external source)

This file assumes the existing stack documented in `.planning/codebase/STACK.md` (Terraform 1.9.8,
`hashicorp/kubernetes` 3.2.1, `grafana/grafana` 4.45.2, one driver module per technology choice, no
Terraform-visible credentials — CI mints them). It does **not** re-recommend anything already shipped.
Every entry below states whether it fits the "declare in Starlark → emit Terraform JSON → `terraform apply`"
model or requires a persistently-running controller, and is scoped as a **new** `drivers/<kind>/<name>` module
per the existing architecture.

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Fits compile-to-TF? | Why Recommended |
|------------|---------|---------|----------------------|------------------|
| `cyrilgdn/postgresql` | 1.27.0 | Postgres/Aurora-Postgres role, database, grant, default-privilege resources | **Yes** — pure Terraform resources (`postgresql_role`, `postgresql_grant`, `postgresql_database`) | The only maintained, widely-adopted Terraform provider for Postgres-native user/role provisioning. Emits exactly the shape this platform already produces: declarative resources in `Component.configs`. New driver: `drivers/database/postgresql`. |
| `petoju/mysql` | 3.0.9 | MySQL/Aurora-MySQL user/grant provisioning | **Yes** — same resource-graph shape as above | Same rationale as Postgres, for the MySQL engine family. Only add if a MySQL-family dependency actually appears; don't build it speculatively. |
| `hashicorp/aws` | ~6.63.x (verify latest patch at implementation time) | Security groups, `aws_db_instance`/`aws_rds_cluster`, `manage_master_user_password`, IAM policies for IRSA | **Yes** — declarative resources | Not yet wired as a real provider in this repo — only an IAM proto schema (`terraform/aws/resources/v5/iam.proto`) is vendored, with no `required_providers` block anywhere. This milestone is where it becomes a real dependency. Vendor v6 proto schemas fresh rather than extending the existing v5 IAM-only vendor tree, since nothing currently locks the repo to v5. |
| `terraform-aws-modules/iam//modules/iam-role-for-service-accounts-eks` (pattern, not the module itself — vendor as proto + Starlark per the platform's "no forked black-box modules" convention) | module v6.8.1 as reference | IRSA: IAM role + trust policy scoped to a K8s ServiceAccount via OIDC | **Yes** — pure `aws_iam_role`/`aws_iam_role_policy_attachment`/`aws_iam_policy` resources, no controller | This is the credential-delivery answer that needs *nothing new at runtime*: a pod's ServiceAccount gets a projected, audience-bound OIDC token; AWS IAM validates it directly. No secret ever exists to leak. Reference the module's resource shape rather than importing it as an opaque HCL module — this platform vendors provider *schemas*, not other people's modules, per `ARCHITECTURE.md`'s anti-pattern list. |
| RDS IAM database authentication (`aws_rds_iam_auth`-style token, `rds_iam` Postgres role, `manage_master_user_password` on the RDS resource) | N/A (AWS native feature) | Credential delivery for DB connections without any password ever appearing in Terraform state or config | **Yes** — declared as attributes on `aws_db_instance`/`aws_rds_cluster` and `postgresql_role` | Extends "credentials never in config" (already a hard constraint in `PROJECT.md`) to the database. `manage_master_user_password = true` hands the *admin* secret to AWS Secrets Manager, never to Terraform state as plaintext. App-level DB roles get `LOGIN` + the engine's IAM-auth grant so app pods authenticate with a short-lived IAM-signed token via their IRSA role, not a stored password. |
| `kubernetes_network_policy_v1` (already in `hashicorp/kubernetes` 3.2.1 — **zero new provider**) | current | Default mechanism for "declared service-to-service edge → network access rule" | **Yes** — native resource, already vendored | This is the cheapest possible answer to requirement #2 (mesh access from a declared edge): the platform already has the Kubernetes provider. A `WithDeps`-style hook that, on seeing an upstream service dependency, emits an allow-rule `NetworkPolicy` scoped to the caller's pod selector needs no new driver dependency at all. Ship this before reaching for a mesh. |
| Linkerd | 2.20 (edge channel: `edge-26.7.x`) | Optional escalation: identity-based mTLS + L7 `AuthorizationPolicy` when NetworkPolicy's L3/L4 model isn't enough | **Yes for the CRDs, no for the control plane** — `Server`/`AuthorizationPolicy`/`HTTPRoute` CRDs are pure `kubernetes_manifest` resources (same provider, no new one); the control-plane install (`linkerd-crds`, `linkerd-control-plane` Helm charts) is a one-time `helm_release` via a new `hashicorp/helm` provider, then runs as a long-lived proxy/control plane in-cluster | CNCF-graduated, smallest CRD surface of the three meshes researched, Rust micro-proxy instead of Envoy (lower operational surface than Istio). The *policy* half — what a driver emits per component — is fully declarative Terraform. The *mesh itself* is a runtime component like ESO or OpenCost below: install once via Terraform, then it runs continuously doing mTLS/proxying, which Terraform does not and should not re-declare per apply. |
| `hashicorp/helm` | 3.1.0 (2.17.0 if the org needs the 2.x line for compatibility reasons) | One-time control-plane installs for Linkerd, ESO, OpenCost — anything shipped as a Helm chart | **Partial** — the `helm_release` resource itself is declarative Terraform, but what it installs is a controller, not a resource graph | New provider dependency this milestone. Needed for exactly the three runtime components below (mesh, secrets sync, cost allocation) and nothing else — don't reach for it to reimplement things the Kubernetes provider already resources natively (Deployments, NetworkPolicy, RBAC). |
| External Secrets Operator (ESO) | Helm chart 2.6.0 (app version tracks `external-secrets` `v0.x` — verify exact app/chart version pairing at install time) | Sync a cloud secret manager entry into a `Secret` object for workloads that cannot do IAM-token auth natively | **No** — it is a reconciling controller (watches `ExternalSecret`/`ClusterSecretStore` CRDs and continuously syncs), not a compile-time artifact | Recommended as the **fallback**, not the default. IRSA + native cloud SDK auth (row above) needs no secret to exist at all; reach for ESO only when a workload expects credentials via env var/file and cannot be changed to call AWS/GCP SDKs directly. Install via `helm_release`; the `ClusterSecretStore`/`ExternalSecret` CRDs it consumes ARE ordinary `kubernetes_manifest` resources a driver can emit per DB dependency. |
| Infracost CLI | latest (verify at install — ships frequent releases; pin a minor in CI) | Cost delta on every Terraform plan, PR comment | **Yes, fully** — reads the exact `outputs/**/*.tf.json` this platform already compiles, before apply | The best-fit FinOps tool for this architecture specifically because it operates on the *compiled artifact*, the same one `protoconf compile` already produces. Add as a step in the derived GitHub Actions pipeline (`drivers/cicd/github_actions`) — no new Terraform provider, no runtime component, no new state. |
| A cross-cutting cost-tagging hook (new Starlark, not a third-party tool) | N/A | Inject `tags`/`labels` (component, team, environment, cost-center) into every emitted AWS resource and every K8s workload | **Yes** — this is exactly the `Inherit`-wrapped hook pattern `WithFailureDomain` already establishes | Cost *attribution* (as opposed to cost *estimation*, which Infracost covers) is only as good as tagging discipline. This is the same mechanism the security-hooks requirement (#3) needs — a hook that "applies across all matching components." Build one mechanism, use it for both security hardening and cost tags. Do not build a second bespoke tagging system. |
| OpenCost | Helm chart tracking OpenCost app releases (CNCF sandbox project; verify current chart version at install — releases roughly quarterly) | Runtime cost *allocation*: reads actual K8s resource usage + cloud billing and attributes real spend to the tags/labels above | **No** — it is a continuously-running allocation engine reading live cluster + billing data, not a Terraform resource | Install once via `helm_release` (same pattern as Linkerd/ESO). It is the natural complement to Infracost: Infracost tells you the cost *before* you apply; OpenCost tells you what was actually spent, broken down by the labels the platform's new tagging hook already stamps onto every `Workload`. Apache-2.0, CNCF-governed, free — start here. |

### Supporting Libraries / Vendored Provider Schemas

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `terraform/postgresql/provider/v1/*.proto` (new, vendor from `cyrilgdn/postgresql` schema) | matches 1.27.0 | Proto-typed `postgresql_role`/`postgresql_grant`/`postgresql_database` messages for the new database driver | Every Postgres/Aurora-Postgres dependency |
| `terraform/aws/resources/v6/{security_group,rds,secretsmanager,iam}.proto` (new) | matches `hashicorp/aws` ~6.63.x | Security-group rules, RDS/Aurora instances, `manage_master_user_password`, IRSA IAM roles | Database driver's network-access and provisioning legs, plus the credential-delivery IRSA module |
| `terraform/kubernetes/resources/v3/network_policy.proto` (new — same `hashicorp/kubernetes` 3.2.1 already vendored, just an additional resource proto) | matches 3.2.1 | Declarative `NetworkPolicy` for the service-mesh-access driver | Every declared service-to-service dependency, as the default (pre-mesh) access mechanism |
| `terraform/linkerd/policy/v1beta1/*.proto` (new, if Linkerd is adopted) | matches Linkerd 2.20 CRD schema | `Server`/`AuthorizationPolicy` CRDs emitted via `kubernetes_manifest` | Only when a component opts into mTLS/L7 authorization beyond NetworkPolicy |
| `terraform/helm/v3/release.proto` (new) | matches `hashicorp/helm` 3.1.0 | `helm_release` for the three one-time control-plane installs (Linkerd, ESO, OpenCost) | Cluster-bootstrap driver(s), not per-component |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Infracost CLI (`infracost breakdown`, `infracost comment github`) | CI cost-diff on every PR | Wire into `drivers/cicd/github_actions`, alongside the existing derived plan/apply pipeline |
| `linkerd check` / `cilium status` (whichever mesh, if any, is chosen) | Post-install mesh health check | Manual/CI smoke check after the one-time Helm install, not part of the per-component driver |

## Installation

```bash
# New Terraform providers (added to whichever generated `main.tf.json` needs them)
# hashicorp/aws        ~> 6.63
# cyrilgdn/postgresql   1.27.0
# petoju/mysql          3.0.9   (only if a MySQL/Aurora-MySQL dependency is declared)
# hashicorp/helm        3.1.0   (only for the one-time mesh/ESO/OpenCost bootstrap driver)

# Protoconf: vendor new provider schemas as proto, same pattern as existing
# terraform/kubernetes and terraform/grafana trees under src/terraform/ and test/src/terraform/
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|--------------------------|
| `cyrilgdn/postgresql` (Terraform-native role provisioning) | Crossplane `provider-sql` | Never for this platform — Crossplane is an in-cluster reconciling controller (a second control plane parallel to Terraform), which directly violates "Terraform applies what the platform emits" (`PROJECT.md` Out of Scope). Only reconsider if the whole platform were migrating off Terraform to Crossplane, which is a different project. |
| IRSA + native RDS/cloud IAM auth | External Secrets Operator + static DB password | Use ESO only when the workload literally cannot authenticate via SDK/IAM token (legacy app expecting `DATABASE_URL` env var). IRSA needs no running component and no secret at rest; ESO needs both. |
| IRSA + native RDS/cloud IAM auth | HashiCorp Vault (dynamic DB secrets engine) | Only if the org already operates Vault for other reasons. Standing up Vault solely for this platform adds a whole second secrets system (its own HA cluster, unseal/auth, policy language) to solve a problem IRSA + cloud-native IAM auth already solves with zero new infrastructure. |
| `NetworkPolicy` (default) + Linkerd (escalation) for service-to-service access | Istio | Istio's CRD surface (`AuthorizationPolicy`, `PeerAuthentication`, `DestinationRule`, `VirtualService`, `Sidecar`, `ServiceEntry`, ...) is real, but it is also the heaviest of the three meshes researched and the most misconfiguration-prone — a bad fit for a driver meant to emit a small, predictable CRD set per dependency edge. Reconsider only if the org needs Istio's traffic-shaping features (canary weighting, fault injection) beyond access control and mTLS. |
| `NetworkPolicy` (default) + Linkerd (escalation) | Cilium Service Mesh | Cilium's `CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` genuinely unify L3/L4 and L7-aware policy in one CRD family, which is attractive. But adopting it means adopting Cilium as the cluster CNI — a cluster-level infrastructure decision far outside a single driver's scope. Worth a dedicated feasibility spike only if the org is already running or planning Cilium as CNI; do not default to it here. |
| OpenCost (free, CNCF) | Kubecost | Use Kubecost only once OpenCost's allocation data proves useful and the org specifically needs multi-cluster rollups, SSO, or governance dashboards — Kubecost is OpenCost plus a commercial layer, not a different tool. Starting with the commercial product before proving the free core is useful is the over-build to avoid. |
| Infracost (pre-apply CI check) | Cloud-native cost tools alone (AWS Cost Explorer / CUR) | CUR/Cost Explorer are the *source of truth* for actual spend and are what OpenCost reads from — they're not a replacement for Infracost's pre-merge estimate, which is the only one of the three that runs before money is spent. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|--------------|
| Crossplane `provider-sql` for DB user provisioning | Imperative in-cluster reconciler, a second execution engine alongside Terraform — the exact thing `PROJECT.md` rules out ("Replacing Terraform as the execution engine") | `cyrilgdn/postgresql` / `petoju/mysql` Terraform providers |
| Storing DB app passwords as Terraform variables or in `Component.configs` | Violates the platform's existing hard constraint ("Credentials never appear in configuration") the moment a DB driver is added carelessly | `manage_master_user_password` (admin) + IRSA/IAM-auth token (app roles) |
| Defaulting to Istio because it's the most well-known mesh | Highest CRD count and operational complexity of the three researched; a driver emitting Istio CRDs per component risks becoming the least "lean" driver in the codebase, working against the one-module-per-choice philosophy | `NetworkPolicy` default, Linkerd for escalation |
| Kubecost as the FinOps default | Commercial tier for features (multi-cluster, SSO, governance) this platform doesn't need yet; OpenCost is the same allocation engine for free | OpenCost, upgrade only if a specific gap appears |
| Vault as a default secrets backend for this milestone | Adds an entire new stateful system (HA Vault cluster, unseal, auth methods) to solve what IRSA + cloud-native IAM auth already solves with zero new infrastructure | IRSA / Workload Identity + cloud secret manager native integration (`manage_master_user_password`) |
| Terraform runners without a documented network path to the database | `cyrilgdn/postgresql`/`petoju/mysql` are the one new provider category in this milestone that must *reach the database over the network* to apply — every other provider (AWS, Kubernetes, Grafana, Helm) only calls a control-plane API. A CI runner with no VPC path to the DB (the common case for GitHub-hosted runners against a private RDS instance) will fail `terraform apply` on this driver specifically. | Self-hosted runners inside the VPC, or a documented bastion/SSM-tunnel step in the CI driver, decided explicitly — not discovered at the first failed apply |

## Stack Patterns by Variant

**If the dependency is Postgres or Aurora-Postgres:**
- Use `cyrilgdn/postgresql` for role/grant/database resources, `aws_rds_iam_auth`-pattern for app credentials.
- Because Postgres has first-class `rds_iam` role support and the provider is the most mature of the two DB providers researched (more resources, more maintenance activity).

**If the dependency is MySQL or Aurora-MySQL:**
- Use `petoju/mysql` (the maintained fork of the original `terraform-providers/mysql`, itself abandoned).
- Because it mirrors the same resource shape as `cyrilgdn/postgresql`, keeping the two DB drivers structurally parallel — same driver-authoring pattern, different engine.

**If a component needs only access control (no mTLS/L7 policy):**
- Use `NetworkPolicy` alone. Do not install a mesh.
- Because a mesh control plane is a new operational surface (upgrades, resource overhead, failure mode) that buys nothing beyond what `NetworkPolicy` already gives you for the common "service A may call service B" case.

**If a component explicitly needs mTLS or L7-aware authorization (e.g., "only GET requests from this identity"):**
- Escalate that component to Linkerd's `Server`/`AuthorizationPolicy` CRDs.
- Because the mesh control plane, once installed for any reason, should be reused rather than re-decided per component — but individual components should not be forced onto the mesh if `NetworkPolicy` already satisfies their access requirement.

**If the org already runs Cilium as CNI:**
- Reconsider Cilium Service Mesh instead of layering Linkerd on top — running two overlapping policy systems (CiliumNetworkPolicy + Kubernetes NetworkPolicy + Linkerd) is worse than picking one.
- This needs its own feasibility research pass before committing; it's a cluster-level decision, not a driver-level one.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|------------------|-------|
| `hashicorp/kubernetes` 3.2.1 (existing) | `kubernetes_network_policy_v1`, `kubernetes_manifest` (for Linkerd/ESO CRDs) | Both resources already ship in the 3.x provider line — no version bump needed to add either capability |
| Terraform 1.9.8 (existing, CI-pinned) | `hashicorp/aws` ~6.63.x, `cyrilgdn/postgresql` 1.27.0, `petoju/mysql` 3.0.9, `hashicorp/helm` 3.1.0 | All four target current Terraform protocol v6/v5-compatible plugin protocol; no known floor above 1.9.8. Verify each provider's stated minimum Terraform version at pin time — do not assume, this is a fast-moving corner. |
| Linkerd 2.20 | Gateway API Mesh profile (GAMMA) | Linkerd has been GAMMA/Mesh-profile conformant since 2.14 — safe to build `HTTPRoute`-based L7 routing on top of the CRDs recommended above if that need arises later |
| `hashicorp/aws` 6.x | `manage_master_user_password` on `aws_db_instance`/`aws_rds_cluster` | Available since AWS provider 5.x; carried forward unchanged into 6.x. No blocker to going straight to 6.x despite the existing vendored proto being labeled v5. |

## Sources

- [cyrilgdn/postgresql provider docs, Terraform Registry](https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs) — HIGH confidence, official registry
- [petoju/mysql provider docs, Terraform Registry](https://registry.terraform.io/providers/petoju/mysql/latest/docs) — HIGH confidence, official registry
- [hashicorp/aws provider, Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest) — HIGH confidence, official registry
- [hashicorp/helm provider, Terraform Registry](https://registry.terraform.io/providers/hashicorp/helm/latest) — HIGH confidence, official registry
- [hashicorp/vault provider, Terraform Registry](https://registry.terraform.io/providers/hashicorp/vault/latest) — HIGH confidence, official registry
- [AWS Database Blog — RDS/Aurora Postgres IAM authentication](https://aws.amazon.com/blogs/database/securing-amazon-rds-and-aurora-postgresql-database-access-with-iam-authentication/) — HIGH confidence, official AWS docs
- [terraform-aws-modules/iam — iam-role-for-service-accounts-eks submodule](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks) — HIGH confidence, official registry, referenced as a resource-shape pattern not an imported dependency
- [External Secrets Operator, ArtifactHub / GitHub releases](https://github.com/external-secrets/external-secrets/releases) — MEDIUM confidence, cross-checked release listing
- [Linkerd releases](https://linkerd.io/releases/) — HIGH confidence, official project page
- [Cilium 1.18 release notes, Isovalent](https://isovalent.com/blog/post/cilium-1-18/) and [Cilium upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/) — HIGH confidence, official/vendor docs
- [Kubernetes Gateway API GAMMA / Mesh support](https://kubernetes.io/blog/2023/08/29/gateway-api-v0-8/) — HIGH confidence, official Kubernetes blog
- Service-mesh comparison synthesis (Istio/Linkerd/Cilium operational complexity, CRD surface, proxy architecture) drawn from multiple independent 2026 comparison articles (reintech.io, calmops.com, kubernetes.ae) — MEDIUM confidence, cross-checked across sources but none is a primary/official comparison
- [Infracost vs OpenCost vs Kubecost positioning](https://www.cloudzero.com/blog/kubecost-vs-opencost/) and related 2026 comparisons — MEDIUM confidence, cross-checked across multiple independent sources, consistent with each tool's own stated purpose (Infracost = pre-apply estimate, OpenCost = CNCF allocation engine, Kubecost = commercial superset)
- Existing codebase: `.planning/codebase/STACK.md`, `.planning/codebase/ARCHITECTURE.md`, `.planning/PROJECT.md`, `providers.tf`, `.terraform.lock.hcl` (read directly to confirm AWS provider is not yet wired) — HIGH confidence, primary source

---
*Stack research for: internal developer platform — database/mesh/security-hook/FinOps fan-out*
*Researched: 2026-09-07*
