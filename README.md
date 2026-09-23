# Platform Engineering

A configuration-as-code platform where every stakeholder in a service's life — the developer,
infrastructure, SRE, security, FinOps — meets on one artifact: the **component**.

A developer declares what a service _is_ and what it _depends on_. The platform derives
everything else from that declaration: the Terraform that deploys it, the address each
dependency hands it, the dashboards and alert rules for what it promises, and the CI
pipeline that applies it in the right order. Add a dependency, and its consequences follow
without the developer naming them.

Built on [Protoconf](https://github.com/protoconf/protoconf): components are Starlark over
proto-typed messages, compiled to Terraform JSON, CI workflows and plain config files.

## Contents

- [Quick start](#quick-start)
- [Concepts](#concepts)
- [Writing a component](#writing-a-component)
- [Declaring objectives](#declaring-objectives)
- [Drivers](#drivers)
- [Setting up a workspace](#setting-up-a-workspace)
- [Compile, apply, and CI](#compile-apply-and-ci)
- [Repository layout](#repository-layout)

## Quick start

You need [`protoconf`](https://github.com/protoconf/protoconf), `terraform` and `make`.

**Compile the reference stack** — two components (an API and its Redis), their SLOs, and
the CI pipeline that applies them:

```bash
cd test
make test        # compile, install the generated workflow, and run the compile-gate checks
ls outputs/core_test/us-east-1/*/     # infra/main.tf.json and monitoring/main.tf.json per component
```

**Run a real stack on a local cluster** — the OpenTelemetry demo's 20 services, with
Prometheus, Grafana, SLOs and generated dashboards. Needs a Kubernetes context (for example
Colima with `--kubernetes`, 6 CPU / 12 GiB):

```bash
cd examples/otel-demo
make apply        # compile and apply every component's state
make monitoring   # push the dashboards and alert rules to Grafana
kubectl port-forward svc/frontend-proxy 8080:8080   # shop at :8080, Grafana at :8080/grafana
```

[`examples/otel-demo/README.md`](examples/otel-demo/README.md) walks through that example
file by file; it is the best place to learn the platform by reading.

**Run it on GKE instead:** [`examples/gke`](examples/gke/README.md) provisions a VPC and a
GKE cluster, and `make apply monitoring DOMAIN=gke` deploys the same demo onto it.

## Concepts

**Component.** A `platform.v1.Component` message: a name, a failure domain, labels,
objectives, upstream components, and a map of configs — each config one file the compiler
writes (`infra/main.tf.json`, `monitoring/main.tf.json`, a service's own YAML).

**Hook.** Every change to a component is a function `f(msg, next) -> msg`. A component is
built by running a list of hooks in order, so concerns compose without knowing about each
other: the developer's workload, the SRE's objectives and the policy team's defaults are all
just more entries in the list. Hooks are typed — a Terraform hook only ever sees a Terraform
config, a component hook only the component — so one list can shape both.

**Markers.** A few declarations are not "change this message", and the component
constructor interprets them instead:

| Marker                            | What it means                                                                                                                                    |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `platform.WithDeps(Factory, ...)` | These components are dependencies. Each is built, attached as an upstream, and its `ForDownstream` hooks run against this component.             |
| `platform.ForDownstream(*hooks)`  | Run these hooks on every component that depends on this one — how a dependency hands over its address, credentials or anything else.             |
| `platform.Inherit(*hooks)`        | Apply these hooks here _and_ to every dependency, transitively — ambient context such as the failure domain. The hooks may be markers: an inherited `WithDeps` is how one dependency — the cluster every workload runs on — reaches every component in a graph without any of them naming it. A component never inherits a dependency on itself. |
| `platform.Finally(*hooks)`        | Run these after everything else, against the finished component — how a dashboard sees every objective, including ones dependencies contributed. |

**Drivers.** Everything technology-specific — Kubernetes, ECS, Terraform state backends,
Grafana, GitHub Actions — is a separate module under `drivers/`. The platform core loads no
driver; a workspace picks the drivers it uses. Replacing Grafana or the CI system is a
different driver, not a change to any component.

**Rendering.** `platform.GetConfigs(root)` walks the dependency graph from a root component
and returns every config keyed `<domain>/<name>/<config>`. An entry point's `main()` returns
that map, and `protoconf compile` writes each entry to `outputs/<entry point>/<key>` —
Terraform JSON, YAML, JSON or TOML, by the key's extension.

## Writing a component

A component is a factory: a function taking `*hooks`, so whatever depends on it can pass
context in. This one is trimmed from the reference stack
([`test/src/core_test.mpconf`](test/src/core_test.mpconf)), which also declares their
objectives and dashboards:

```python
load("@kubernetes//kubernetes.pinc", "WithContainerEnv", "Workload")
load("@platform//platform/platform.pinc", "platform")
load("@terraform_state//terraform.pinc", "S3Backend", "WithState")

BACKEND = S3Backend("platform-engineering-tfstate", "us-east-1",
                    lambda domain, name: "%s/%s.tfstate" % (domain, name))

def RedisComponent(*hooks):
    return platform.Component(
        "redis",
        # how it runs: its own Terraform state holding a Kubernetes workload
        WithState(lambda component: Workload("redis", "redis:7-alpine", 6379), BACKEND),
        # what it hands to anything that depends on it
        platform.ForDownstream(
            platform.WithConfig(None, WithContainerEnv("REDIS_URL", "redis://redis:6379")),
        ),
        *hooks
    )

def ApiTaskComponent(*hooks):
    return platform.Component(
        "api-task",
        WithState(lambda component: Workload("api-task", "ghcr.io/example/api:latest", 8080), BACKEND),
        # uninstantiated: the platform builds it, and api-task receives REDIS_URL
        platform.WithDeps(RedisComponent),
        *hooks
    )

def main():
    return platform.GetConfigs(ApiTaskComponent(platform.WithFailureDomain("us-east-1")).msg)
```

Things worth knowing when writing one:

- **Order is meaningful** where one hook reads another's work: a hook that reads a label has
  to come after the `WithLabels` that sets it.
- **Terraform hooks need a config to change.** `WithContainerEnv` edits a Deployment, so it
  runs inside `platform.WithConfig(None, ...)` after `WithState` has created one — not bare in
  the component's list, where it would run first and find nothing.
- **Pass the dependency, not an address.** If you are about to write another component's
  hostname, that component should hand it over with `ForDownstream` instead.
- **Repeated setup belongs in a macro.** A function returning a tuple of hooks — a
  `Defaults(*hooks)` every component ends with, say — is how an organisation applies policy to
  every component in one place. `examples/otel-demo/src/components/defaults.pinc` is one.
- **Labels describe shape.** `platform.WithLabels(tier = "cache")` records what a component
  is, and `platform.SelectComponents(root, predicate)` returns every component in a graph
  matching a predicate over them — the basis for cross-cutting policy.

## Declaring objectives

Objectives are declared on the component; a monitoring driver renders them. The component
never knows dashboards exist.

```python
platform.WithSLO(
    "availability",
    'sum(rate(http_requests_total{job="api",code!~"5.."}[28d])) / sum(rate(http_requests_total{job="api"}[28d]))',
    description = "Share of requests answered without a 5xx",
    min = 0.995,
    unit = platform.Unit.UNIT_RATIO,
    severity = platform.Status.STATUS_CRIT,
    # the same ratio over the alert's own windows: this is what makes a burn-rate alert
    burn_query = 'sum(rate(http_requests_total{job="api",code!~"5.."}[$__window])) / sum(rate(http_requests_total{job="api"}[$__window]))',
)
platform.WithDiagnostic("pod restarts", "sum(increase(kube_pod_container_status_restarts_total[1h]))",
                        unit = platform.Unit.UNIT_COUNT)
```

- **`WithSLO`** is a promise: a query, a bound (`min` for a ratio, `max` for a ceiling), a
  unit and a severity. A `burn_query` gives it multiwindow burn-rate alerts; without one, a
  `threshold_alert` gives it a plain threshold rule.
- **`WithDiagnostic`** is not a promise: a signal on the dashboard that explains a broken
  objective, and never pages.
- **`WithGrafanaDashboard(backend, datasources)`** (in the Grafana driver) renders one
  dashboard per component with objectives — SLO panels, an alert list for its dependencies,
  diagnostics — plus the alert rules, into the component's `monitoring/main.tf.json` state.
  `datasources` maps a kind (`prometheus`, `cloudwatch`, `postgres`) to your Grafana's name
  for it.
- Proto3 cannot tell a bound of `0.0` from no bound; an objective that bounds at zero needs
  another shape.

## Drivers

Load a driver by the label you gave it in `CONFIGSPACE`.

| Driver             | Module                        | Main symbols                                                                                                                                                                       |
| ------------------ | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kubernetes runtime | `drivers/runtime/kubernetes`  | `Workload(name, image, port)`, `KubeConfig`, and workload hooks `WithContainerEnv`, `WithCommand`, `WithMemoryLimit`, `WithPort`, `WithConfigFiles`, `WithScratchDir`              |
| ECS runtime        | `drivers/runtime/ecs`         | `ecs.WithTask`, `WithContainer`, `WithTaskEnv`, `WithTaskSecret`                                                                                                                   |
| GKE cluster        | `drivers/cluster/gke`         | `gke.Gcp(project, region, …)` and the components it configures: `gke.Network`, `gke.Subnet`, `gke.Router`, `gke.Nat`, `gke.Cluster`. A component depending on the cluster is handed its endpoint, CA and a token, so nothing it applies needs a kubeconfig |
| Terraform state    | `drivers/state/terraform`     | `WithState(contents, backend)`; backends `S3Backend`, `GCSBackend`, `AzureRMBackend`, `RemoteBackend`, `LocalBackend`; cross-state values with `WithRemoteOutput` / `RemoteOutput` |
| Grafana monitoring | `drivers/monitoring/grafana`  | `WithGrafanaDashboard(backend, datasources)`                                                                                                                                       |
| GitHub Actions CI  | `drivers/cicd/github_actions` | `actions.TerraformPipeline(configs, output_root, credentials, frozen = …)`; credentials `OidcCredentials` and `AccessKeyCredentials` (AWS), `GoogleOidcCredentials` (GCP, keyless — and what authenticates a GKE workload's Kubernetes provider too), `GrafanaServiceAccountToken` |

Everything the platform core offers is on the `platform` struct from
`@platform//platform/platform.pinc`: `Component`, the markers above, `WithConfig`,
`WithDescription`, `WithFailureDomain`, `WithLabels`, `WithFreeze`, `WithSLO`,
`WithDiagnostic`, `GetConfigs`, `SelectComponents`, `FrozenComponents`, and the hook plumbing (`chain`, `component_filter`,
`terraform_filter`, `mutate_config`).

## Setting up a workspace

A workspace is a directory with a `CONFIGSPACE`, a `src/` holding its entry points and
components, and the provider protos its drivers use. `test/` and `examples/otel-demo/` are
both workspaces; copying one is the fastest start.

```python
# CONFIGSPACE — one module per driver, so importing Grafana does not drag in ECS
platform=remote_repo(label="platform", url="git@github.com:smintz/platform-engineering.git", tag="v0.1.1")
kubernetes=remote_repo(label="kubernetes", url="git@github.com:smintz/platform-engineering.git//drivers/runtime/kubernetes", tag="v0.1.1")
terraform_state=remote_repo(label="terraform_state", url="git@github.com:smintz/platform-engineering.git//drivers/state/terraform", tag="v0.1.1")
```

- `src/<name>.mpconf` is an entry point: its `main()` returns the configs to write.
- `src/terraform/` holds the generated provider protos the drivers load
  (`test/src/terraform` has Kubernetes and Grafana; the example symlinks it).
- Your own config file formats can be proto messages too: build them in Starlark, set them on
  the component under a key like `infra/config.yaml`, and pass their types to
  `platform.GetConfigs(root, types)` so they are written beside the component's state. The
  example's `src/otelcol/v1` and `components/demo.pinc` show how.

Organisation-specific values — bucket names, regions, datasource names — belong in the
workspace, passed to drivers as arguments. Drivers stay reusable.

## Compile, apply, and CI

```bash
protoconf mod tidy          # resolve CONFIGSPACE modules
protoconf compile .         # write materialized_config/ and outputs/
terraform -chdir=outputs/<entry>/<domain>/<name>/infra init
terraform -chdir=outputs/<entry>/<domain>/<name>/infra apply
```

Each component config is its own Terraform state. Rather than applying them by hand, return
a pipeline from `main()`:

```python
outputs[".github/workflows/terraform.yaml"] = actions.TerraformPipeline(
    configs, OUTPUT_ROOT, actions.OidcCredentials("us-east-1"))
```

It plans every state on pull requests and applies on `main`, **ordered by what each state
reads from which** — the order is derived from backend keys and `terraform_remote_state`
reads, never declared. It refuses to compile, with a message naming the fix, when a state
CI would apply has no remote backend, or when a state reads one that no config produces.

Generated output is committed. The `drift` workflow (`.github/workflows/drift.yaml`)
recompiles the reference stack whenever `src/`, `drivers/`, `test/src/`, `test/CONFIGSPACE`
or `test/protoconf.lock` change, and fails if the committed output differs — so after
changing anything that affects output, run `cd test && make test` and commit the result.
It covers `test/` only: an example's committed output is yours to regenerate with its own
`make compile`.

## Repository layout

```
src/platform/        the platform core: components, hooks, markers, objectives (platform.pinc is the facade)
src/terraform/v1/    the Terraform DSL the drivers build configs with
drivers/<kind>/<n>/  one module per technology choice: runtime, cluster, state, monitoring, cicd
test/                the reference workspace and golden output; `make test` is the build
examples/otel-demo/  the OpenTelemetry demo on a local cluster or on GKE it provisions itself
examples/gke/        the GKE driver's components on their own: a VPC and a cluster, nothing on it
.github/workflows/   the drift check (hand-written) and the generated Terraform pipeline
.planning/           roadmap and requirements for the platform's development
```
