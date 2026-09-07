# Architecture Research: Dependency Fan-Out and Cross-Cutting Policy

**Domain:** Declarative platform engineering — extending an existing compile-time hook-chain
component model (no runtime controller) with two-sided dependency provisioning and
shape-based cross-cutting policy.
**Researched:** 2026-09-07
**Confidence:** MEDIUM (findings cross-checked across each project's own docs — docs.crossplane.io,
kubevela.io, docs.score.dev, developer.hashicorp.com, kyverno.io, open-policy-agent.github.io —
but sourced via general web search rather than a curated/verified provider, so treat specifics
as directionally reliable and verify version-specific API names before implementing)

## Answer, In One Paragraph

Every declarative system surveyed solves the two-sided-dependency problem the same
structural way this codebase already solves it for `WithRemoteOutput`: one authoring point
produces **two hooks that close over shared state**, one applied to the provider, one deferred
onto the consumer — and ordering is guaranteed not by waiting, but by the provider hook always
running to completion before the consumer hook fires. This repo has that primitive already
(`WithDeps` + `ForDownstream`); the DB/mesh work is *applying it a second time*, not inventing
it. Cross-cutting policy is structurally different everywhere it's solved well: it is never
inlined into the thing it targets (a trait mutates only its own component; a Kyverno/Gatekeeper
rule is a separate object with its own match block). The transferable idea is **separating the
selector from the action** and making selection test a **declared, cheap field** (a label, a
`type`) rather than introspect the rendered artifact. This repo has no such field today — that's
the one schema gap worth closing.

## Comparative Survey

| System | Two-sided dependency mechanism | Cross-cutting selection mechanism | What transfers to a compile-time hook chain |
|---|---|---|---|
| **Crossplane Compositions** | Provider-side composed resource sets `writeConnectionSecretToRef` + a `connectionDetails` allowlist of which keys to publish; the Composition (or `function-patch-and-transform`) aggregates those into one secret the consumer reads. A later pipeline step references an earlier step's named resource without re-declaring it. | No native "select existing resources by shape" primitive inside one Composition — selection happens one level up, via `compositionSelector.matchLabels` on the *claim*, choosing which Composition to run at all. | The **allowlist-of-published-fields** idea: a provider-side hook should declare *which* values it exposes (a small struct), not let the consumer-side hook reach into arbitrary internals via a bespoke closure per hook author. Worth adopting as a naming convention on top of the existing closed-over-cell pattern. |
| **KubeVela / OAM traits** | Traits are **single-sided only** — a trait patches its own component's rendered manifest (e.g. `spec.template.spec.containers`) via a `patchKey` merge-or-append; `appliesToWorkloads` restricts which workload kinds may receive it. Traits cannot mutate a *different* component. | OAM deliberately puts cross-cutting selection in a **separate concept**, `policy`, applied once at the Application level (not per-trait), selecting components by declared `type` or `name` — never by parsing the rendered YAML. | The **separation itself**: OAM never conflates "mutate the thing I'm attached to" (≈ this repo's ordinary hook) with "select a subset of the whole app by declared type" (≈ what's missing here). Also: select by a **declared field**, not by inspecting output — directly informs adding a `tags`-like field to `Component`. |
| **Score** | One `resources.<id>` provisioner declaration is realized by **one provisioner function** that emits both the provider-side objects (StatefulSet/Service/Secret/init Job for Postgres) *and* the outputs map (`${resources.db.host}` etc.) the workload's own env/files reference. Both sides come from a single authoring point. | Not a design goal of Score — it's a single-workload spec, not a multi-component graph; no selection primitive exists. | Confirms the design choice already implicit in `WithRemoteOutput`: **one factory returns both halves**, so a call site cannot wire the provider side without the consumer side (or vice versa) drifting out of sync. |
| **Terraform module composition** | Root-level composition: `module.B.some_input = module.A.some_output`. Terraform builds the dependency graph from the reference itself — no explicit ordering primitive needed. Community best practice: **dependency injection** (root passes resources into modules) over each module looking its own dependency up. | N/A — Terraform has no resource-selection-by-shape concept; `for_each`/`count` iterate over statically-known collections, not a live graph of typed resources. | This *is* the mechanism this repo already uses for ordering: the CI driver recovers apply order by matching `terraform_remote_state` reads against backend keys — a reference *is* the dependency edge, resolved at plan/CI time, never by waiting on a live controller. The two-sided DB/mesh work should keep riding this substrate, not invent a new "wait" step. |
| **Kyverno / OPA Gatekeeper** | N/A — these are admission-time policy engines, not provisioners; they don't produce two-sided infrastructure. | Cleanly **separates the selector from the logic**: a `match` block (`kinds` + `namespaceSelector`/`selector`, label-based, ANDed together) decides *which* resources a rule sees; the Rego/CEL body then inspects arbitrary `spec` fields for the actual shape test (e.g. `spec.rules[_].host`). | The exact shape of what's missing here: a **declarative, structural match** (cheap field/label test) *plus* a separately-authored **hook to apply to matches**. This is the strongest transferable idea in the whole survey and maps directly onto the recommended `Component.tags` + a graph-walking selector, below. |

## Component Boundaries (existing vocabulary, extended)

| Component | Responsibility | Status |
|---|---|---|
| `platform.v1.Component.tags` (proto) | A small `map<string,string>` on `Component`, populated by hooks as a declarative side effect ("ingress: public", "datastore: true") — the *only* thing cross-cutting policy is allowed to test against | **New** — one additive proto field, `src/platform/v1/platform.proto` |
| `WithDeps` / `ForDownstream` (existing) | Already the two-sided fan-out primitive: a dependency mutates itself (provider side) during its own `Component()` construction, then `RunForDownstream` fires its `ForDownstream` hooks against the consumer (consumer side) | **Unchanged** — this is the mechanism to reuse, not replace |
| Two-sided hook pairs (`WithRemoteOutput` today; `WithDatabaseUser`, `WithMeshAccess` new) | One factory returning `(near_hook, far_hook)` that close over a shared Starlark cell — near writes the provider-side resource, far (wrapped in `ForDownstream`) writes the consumer-side resource using values the near half recorded | **Extend the existing pattern**, driver-level only |
| `drivers/database/<engine>/` | New driver: near half provisions a DB user/role + grant (`postgresql_role`, `aws_db_user`, security-group ingress on the DB side); far half writes a secret reference and a security-group/NSG rule onto the consumer, and sets `tags["datastore"] = "true"` | **New driver module** — zero core change beyond the `tags` field |
| `drivers/mesh/<istio\|linkerd>/` | New driver: near half writes a provider-side traffic policy (e.g. an AuthorizationPolicy admitting the consumer's identity); far half writes the consumer-side client config (ServiceEntry/route) and sets `tags["mesh"] = "true"` | **New driver module** — zero core change |
| `walk_upstreams` (existing, private to `core.pinc`) | Depth-first traversal of `component.upstreams.components`, currently used only by `GetConfigs` | **Factor out and export** — small refactor so a new selector can reuse the exact traversal `GetConfigs` already proves correct, instead of duplicating it |
| `SelectComponents(root, predicate)` (new, `core.pinc` or a sibling `policy.pinc`) | Walks the same upstream tree as `GetConfigs`, returns every component whose `.tags` (or `.domain`/`.name`) satisfies `predicate` | **New function**, not a new marker — reuses already-exported `chain`/`mutate_config` to re-apply hooks to the matched subset |
| Cross-cutting policy call site (e.g. `src/platform/policy.pinc` or organisation-level `.mpconf`) | `for c in platform.SelectComponents(root, is_public_ingress): platform.mutate_config(c, MAIN_CONFIG, *hardening_hooks); platform.chain(c, *hardening_hooks)` | **New library, not a new marker kind** — a second, deliberate pass over an already-built tree |
| `WithCostCenter(...)` (new, `Inherit`-wrapped, driver or `core.pinc` sibling) | Ambient cost/owner tags applied to every resource a component and its dependencies emit — structurally identical to the existing `WithFailureDomain` | **Fits the existing `Inherit` marker exactly** — no new concept at all |

## Data Flow

### A two-sided dependency (DB, mesh) — extends the existing `WithDeps`/`ForDownstream` flow

```
call site: ApiTaskComponent(WithDeps(PostgresComponent))
  │
  ▼
Component() builds PostgresComponent first (inherited hooks first, then its own)
  │  during that build, the *near* half of WithDatabaseUser runs as an ordinary
  │  hook on the Postgres component itself:
  │    - emits the provider-side Terraform resource (DB user/role + grant)
  │    - records generated values (username, host, grant ARN) into a closed-over
  │      Starlark cell — same trick as WithRemoteOutput's `publisher = []`
  │    - sets postgres.msg.tags["datastore"] = "true"
  ▼
dep.msg is appended to api-task.upstreams.components
  ▼
dep.RunForDownstream(api-task)  — fires the *far* half, which is ForDownstream-wrapped
  │  reads the same closed-over cell (guaranteed populated: the near half already
  │  ran to completion as part of building `dep`, which happened before this line)
  │    - emits the consumer-side Terraform resource (secret data source /
  │      Kubernetes Secret ref, ingress security-group rule on the consumer)
  ▼
api-task.msg now carries both: the dependency edge (upstreams) and the consumer-
  side resource in its own main.tf.json — GetConfigs walks upstreams and emits both
  states; ordering between them is recovered the same way it already is for
  WithRemoteOutput (backend-key ↔ terraform_remote_state matching in the CI driver),
  or is a native Terraform dependency if provider and consumer share one state.
```

**Why this avoids ordering bugs by construction, not by convention:** `Component()`
already builds a dependency completely — including every hook in *its* chain — before
calling `dep.RunForDownstream(component)` (`src/platform/core.pinc:158-164`). The far half is
therefore never invoked before the near half has finished mutating the shared cell. This is
the same guarantee Terraform's own module composition gets from output→input references
(the reference *is* the ordering constraint) and the same guarantee Crossplane gets from
pipeline step ordering — except here it falls out of plain Starlark call order, for free,
with no readiness polling required.

### Cross-cutting policy ("all components with a public ingress")

```
call site: root = ApiTaskComponent(...)   # whole tree built once, as today
  │
  ▼
targets = platform.SelectComponents(root.msg, lambda c: c.tags.get("ingress") == "public")
  │   walks component.upstreams.components exactly like GetConfigs already does —
  │   tests only the declared `tags` field, never Terraform internals inside `configs`
  ▼
for t in targets:
    platform.mutate_config(t, MAIN_CONFIG, *security_hardening_hooks)
    platform.chain(t, *security_hardening_hooks)
  │   ordinary hooks re-applied to an already-built message — chain()/mutate_config()
  │   are plain functions over a mutable proto message, already exported on `platform`
  ▼
main() returns platform.GetConfigs(root.msg) as before — hardened components' configs
  are already mutated in place by the time GetConfigs walks the tree
```

**Why `tags`, not Terraform introspection:** `Component.configs` holds `google.protobuf.Any`
values that `mutate_config` explicitly documents as "assumes Terraform" (a known wart, not a
pattern to extend). Testing "has a public ingress" by unpacking that Any and walking Terraform
resource fields would couple the policy layer to Terraform's schema and to each driver's
internal resource shape. Kyverno/Gatekeeper's match-by-label and OAM's `type`-based
`componentSelector` both avoid this by testing a **cheap, declared** field instead of the
rendered artifact — that's the one idea worth a schema change to import.

## Which pieces need a core change vs. are pure driver/library work

**Needs a core change (small, additive):**
- `platform.v1.Component.tags` — one `map<string,string>` proto field. Nothing else in
  `core.pinc`'s hook-chain plumbing needs to change; `chain`, `mutate_config`, markers, and
  `Component()`'s construction order are all sufficient as-is.
- Exporting `walk_upstreams` (or a `SelectComponents` built from it) from `core.pinc` — a
  refactor, not new behavior; `GetConfigs` already proves the traversal correct.

**No core change required — pure driver or library work:**
- The DB two-sided pattern (`drivers/database/<engine>/`) — reuses `WithDeps`, `ForDownstream`,
  `Inherit`, `mutate_config`, exactly as `WithRemoteOutput` already does.
- The mesh two-sided pattern (`drivers/mesh/<name>/`) — same reuse, independent driver.
- Cost attribution (`WithCostCenter`) — fits the existing `Inherit` marker precisely, the same
  shape as `WithFailureDomain`. This is the cheapest of the four Active requirements to ship
  and validates nothing new about the architecture — it's just another ambient hook.
- The cross-cutting policy *application* itself (the loop over `SelectComponents` results) —
  a library file, not a new marker kind, because `chain`/`mutate_config` are already free
  functions usable outside `Component()`'s own construction.

**Explicitly NOT recommended:** a new marker kind (a fifth `module(..., kind=...)` alongside
`deps`/`downstream`/`inherit`/`finalize`) for cross-cutting policy. Markers exist because some
instructions "cannot be expressed as mutate this message" (per `core.pinc`'s own comment) —
but selecting-then-mutating a subset of an already-built tree *can* be expressed as an ordinary
Starlark loop calling already-exported functions. Adding a marker here would be inventing
ceremony for something `chain()` and `mutate_config()` already do.

## Suggested Build Order

1. **Cost attribution (`WithCostCenter`, `Inherit`-wrapped).** Ships first because it needs
   nothing new — proves out FinOps tagging using a marker that already exists, and gives every
   later driver a place to also emit cost tags as a matter of course.
2. **`Component.tags` schema field + factor `walk_upstreams` into an exported `SelectComponents`.**
   Small, additive, unblocks everything shape-based. Worthless alone (nothing populates it yet),
   so land it together with, or immediately before, step 3.
3. **Database two-sided driver (`drivers/database/<engine>/`).** Generalizes
   `WithRemoteOutput`'s near/far-pair convention into a second real use, and is the first driver
   to populate `tags["datastore"]`. This is the requirement most worth doing first among the
   two-sided ones, because it's also the one PROJECT.md's Active requirements list leads with.
4. **Service mesh two-sided driver (`drivers/mesh/<name>/`).** Independent of step 3 once the
   near/far-pair convention from step 3 is validated; can run in parallel with it if two people
   are available, sequential if one.
5. **Cross-cutting security policy (`SelectComponents` + a policy library, e.g.
   `src/platform/policy.pinc`).** Sequenced last on purpose: it needs `tags` (step 2) *and* it
   needs at least one driver (step 3 and/or a component that sets `tags["ingress"]="public"`)
   actually populating tags, or there is nothing meaningful to select against yet.

**Cross-cutting note for whoever plans phase content:** steps 1 and 2 are cheap and mostly
mechanical; steps 3–5 are where the "does the fan-out actually compose without the consumer
knowing" thesis from `PROJECT.md` gets tested for real, the way `WithSLO`→Grafana already
proved it for monitoring. Budget research/discovery time there, not on the schema field.

## Anti-Patterns Specific to This Extension

### Testing shape by unpacking `configs` instead of reading `tags`
**What people will be tempted to do:** write a predicate that unpacks a component's
`google.protobuf.Any` configs and inspects Terraform resource types to decide "does this have
a public ingress."
**Why it's wrong:** couples the policy layer to Terraform's schema and to each driver's
internal resource shape, and `mutate_config`'s own comment already flags "assumes Terraform"
as a wart, not a pattern to build on.
**Do this instead:** the hook that creates the semantic thing (`WithIngress(public=True)`, the
database driver, the mesh driver) sets a `tags` entry as a side effect. Policy tests `tags` only.

### A cross-cutting hook that calls `WithDeps`
**What people will be tempted to do:** have a security-hardening cross-cutting hook add a new
upstream dependency to a matched component (e.g. "every public-ingress component gets a WAF
sidecar dependency").
**Why it's wrong:** `SelectComponents`/cross-cutting policy runs as a second pass, after
`Component()` has already finished building the whole tree once. There is no third pass — a
new `WithDeps` entry added at this point would never get its own `ForDownstream` machinery run.
**Do this instead:** if a cross-cutting concern genuinely needs to add a dependency, it belongs
inside the component's own hook list (ordinary `WithDeps`) or as an `Inherit`-wrapped hook
applied at declaration time, not as a post-hoc policy pass.

### Reinventing the near/far pair per hook instead of reusing the convention
**What people will be tempted to do:** write the database and mesh drivers' two-sided hooks
each with their own bespoke closure shape, the way a brand-new pattern would be designed from
scratch.
**Why it's wrong:** `WithRemoteOutput` already proves the shape (near hook mutates + records
into a shared cell, far hook is `ForDownstream`-wrapped and reads the same cell) — reinventing
it invites the two halves to drift, exactly the failure Crossplane's `connectionDetails`
allowlist and `writeConnectionSecretToRef` are designed to prevent on their side.
**Do this instead:** every new two-sided dependency driver should be reviewable against
`WithRemoteOutput` line by line — same shape, different payload.

## What a Compile-Time-Only Model Genuinely Cannot Do

Be explicit about these with whoever is planning the roadmap — they are real gaps, not
missing polish:

1. **No drift detection against out-of-band changes.** Kyverno/Gatekeeper intercept every
   admission request at runtime, so a resource created by `kubectl apply` or a console click
   still gets policed. This platform only governs what passes through `protoconf compile` +
   `terraform apply`; a manually created security-group rule or a manually deleted secret is
   invisible to it, forever, until someone notices in a drift-detection tool this platform
   doesn't have.
2. **No true readiness gating, only plan/apply ordering.** Crossplane polls real infrastructure
   and only materializes a downstream secret once the upstream resource is actually `Ready`.
   This platform's guarantee is that the *reference* exists in the right order (Terraform's
   own graph within one state, or CI job order recovered from backend-key matching across
   states) — it has no way to know whether the referenced infrastructure is *actually* usable
   yet. A DB user resource created immediately after the DB instance resource, in the same
   apply, can still race the DB's own bring-up if Terraform's provider doesn't already block on
   that internally.
3. **No dynamic re-evaluation.** `SelectComponents` runs once, at compile time, over one
   config space's tree. A component declared in a different `.mpconf` (a different root) is
   invisible to it. A runtime policy controller re-evaluates on every new or changed resource;
   here, "all components with a public ingress" is only ever as current as the last
   `protoconf compile`.
4. **No self-healing.** If someone deletes the consumer-side secret reference by hand, nothing
   notices or recreates it until the next full `protoconf compile` + `terraform apply` cycle.

None of these are reasons to add a runtime controller — `PROJECT.md`'s constraints rule that
out, and the CI-derived apply-order mechanism already gets most of the practical benefit
(ordering) without one. They are reasons to document, in the roadmap, that "cross-cutting
policy" here means "compile-time policy applied to what's declared," and to make sure nobody
downstream mistakes it for an admission-time guarantee.

## Sources

- [Connection Details Composition · Crossplane v2.4](https://docs.crossplane.io/latest/guides/connection-details-composition/)
- [Function Patch and Transform · Crossplane v2.4](https://docs.crossplane.io/latest/guides/function-patch-and-transform/)
- [Compositions · Crossplane v2.4](https://docs.crossplane.io/latest/composition/compositions/)
- [Patch in the Definitions | KubeVela](https://kubevela.io/docs/platform-engineers/traits/patch-trait/)
- [Trait Definition | KubeVela](https://kubevela.io/docs/platform-engineers/traits/customize-trait/)
- [Built-in Policy Type | KubeVela](https://kubevela.io/docs/end-user/policies/references/)
- [Resource Provisioners | Score](http://docs.score.dev/examples/resource-provisioners/)
- [Local state | Score](https://docs.score.dev/docs/score-implementation/local-state/)
- [Module Composition | Terraform | HashiCorp Developer](https://developer.hashicorp.com/terraform/language/modules/develop/composition)
- [Selecting Resources | Kyverno](https://kyverno.io/docs/policy-types/cluster-policy/match-exclude/)
- [Constraint Templates | Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/docs/constrainttemplates/)
- This repo: `src/platform/core.pinc`, `src/platform/platform.pinc`, `drivers/state/terraform/src/terraform.pinc` (`WithRemoteOutput`, read directly, HIGH confidence — primary source)

---
*Architecture research for: two-sided dependency fan-out and shape-based cross-cutting policy
inside an existing compile-time hook-chain platform*
*Researched: 2026-09-07*
