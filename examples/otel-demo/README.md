# OpenTelemetry demo on the platform

The [OpenTelemetry demo](https://github.com/open-telemetry/opentelemetry-demo)'s 20 core
services (`compose.yaml`), plus a Prometheus, Jaeger and Grafana stack, declared as platform
components and applied to a local cluster. Every request-serving service declares SLOs,
and the platform renders them into Grafana dashboards and burn-rate alert rules.
An exercise in how the platform's practices hold up against a real, dependency-heavy stack.

```bash
make compile      # src/otel_demo.mpconf -> outputs/otel_demo/colima/<service>/{infra,monitoring}/main.tf.json
make apply        # one local-state Terraform apply per service, against kubectl's current context
make monitoring   # dashboards and alert rules, applied to Grafana through a port-forward
make destroy
kubectl port-forward svc/frontend-proxy 8080:8080   # storefront at http://localhost:8080
                                                    # Grafana at http://localhost:8080/grafana (admin/admin)
                                                    # Jaeger at http://localhost:8080/jaeger/ui
```

Sized for about 4.8 GiB of memory limits; a Colima VM with 6 CPU and 12 GiB is comfortable.

## How to read it

```
src/otel_demo.mpconf           the inventory: names the root component, nothing else
src/components/cart.pinc       start here — the shape every component follows
src/components/demo.pinc       the hooks components are written with
src/components/defaults.pinc   what every component gets (dashboards), and where state lives
src/components/objectives.pinc what a request-serving component promises
src/components/<service>.pinc  one component per file
```

A component is a list of hooks, one concern each, read top to bottom:

```python
def CartComponent(*hooks):
    return platform.Component(
        "cart",
        platform.WithDescription("Shopping cart, kept in Valkey"),   # what it is
        platform.WithLabels(criticality = "high"),                   #   and its shape
        WithDemoWorkload(                                            # how it runs
            DemoImage("cart"),
            8080,
            WithEnv(CART_PORT = "8080", ASPNETCORE_URLS = "http://*:8080"),
            WithMemoryLimit("160Mi"),
        ),
        platform.WithDeps(Collector("grpc"), FlagdComponent, ValkeyCartComponent),  # what it needs
        WithDependantEnv(CART_ADDR = "cart:8080"),                   # what it hands its dependants
        WithRequestObjectives(200),                                  # what it promises
        Defaults(*hooks),                                            # what everything gets
    )
```

- **Adding a service** is a new file in that shape, and one entry in the `WithDeps` of
  whatever calls it. Nothing else changes: its dependencies hand it their addresses, and its
  objectives become a dashboard because `Defaults` is on the list.
- **Hooks inside `WithDemoWorkload`** shape the Kubernetes workload, and run once it exists.
  Hooks on the component describe the component itself.
- **Order matters where one hook reads another's work.** `WithRequestObjectives` reads the
  `criticality` label for its severity, so `WithLabels` comes first.
- **`Collector("grpc")`** is a component factory with a parameter: a dependant chooses the
  protocol it will export in, and receives the matching endpoint.
- **Config files are typed messages.** Each tool's file format has a schema under `src/`
  (`otelcol/v1`, `prometheus/v1`, `grafana/provisioning/v1`, `opentelemetry/sdk/v1`,
  `flagd/v1`), and a component builds its file with those message constructors
  (`COLLECTOR_CONFIG`, `PROMETHEUS_CONFIG`, `FLAGS`, …), declared with
  `WithConfigFile(name, mount_path, filename, content)`. A misspelled key is a compile
  error. The compiler serializes the message in the format the filename's extension names,
  beside the component's `main.tf.json`, and the ConfigMap reads it from there.
  - A new config message goes in `CONFIG_FILE_TYPES` in `demo.pinc`, which `main()` hands to
    `GetConfigs`; `WithConfigFile` fails at compile time if it is missing.
  - Being data, a config can reuse other data: Grafana's provisioned datasource takes its
    name from the same `DATASOURCES` the dashboards look it up by.
  - Proto3 leaves out fields at their default, so `false` settings do not appear in the
    files; every one of them is the tool's own default too.

## Where things come from

- **Services and dependency edges:** the demo's `compose.yaml` (`depends_on`).
- **Images, ports, memory, environment:** its Helm chart (demo `3.0.0`), the demo's own
  description of running these images on Kubernetes.
- **Config files:** translated into Starlark from the demo — the SDK config in
  `product_catalog.pinc` and the Prometheus config from the repo, the flags in `flagd.pinc`
  from the chart. The collector config and Grafana datasource are new: an OTLP collector
  deriving span metrics into Prometheus, and the one datasource the dashboards query. Each
  generated file was checked to parse to exactly the data of the file it replaced.
- **`files/`:** only `init.sql`, from the demo repo — SQL is not data the compiler can
  serialize, so it stays a file.
- **`src/terraform`:** a symlink to `test/src/terraform`, the vendored provider protos.

## Objectives

Shaped after the components in leap-infra (`infra/compononets`): objectives are declared on
the component, a `Defaults` macro adds `WithGrafanaDashboard` to every component, and a
component with no objectives renders no dashboard.

- **Who and what:** shoppers, who feel a request that failed or was slow.
- **Measured at:** each service's own server spans, turned into request metrics by the
  collector's `span_metrics` connector. One query shape covers services in eleven languages
  that share no metric names. It misses the network to the caller.
- **Per service (12 request-serving ones):** availability (non-error server spans / all
  server spans) and latency (share under a per-service threshold), both over 28 days with a
  `burn_query`, plus two diagnostics (request rate, errors by operation).
- **Severity:** from the demo's own `service.criticality` label — critical services page,
  the rest ticket.
- **Targets are provisional** (99.5% availability, 99% under threshold). Nothing measured
  these services before, so they are a first guess to reset from a few weeks of data.
- **Scope:** `frontend-proxy` also fronts Grafana, so its objective excludes
  `upstream_cluster="grafana"`. Without that, Grafana crashing reads as shoppers failing.
  Envoy does not tag every route with `upstream_cluster`; untagged requests stay in the
  objective, which is where storefront traffic belongs. Series recorded before the
  dimension existed carry no label either, so Grafana's earlier 503s stay in the 28-day
  number until they age out of the window.

## What the exercise showed

**Dependency wiring fans out as designed.** No service writes another service's address.
Each service declares `WithDeps(...)`, and each dependency hands its own address downstream
with `ForDownstream`: `checkout` gets `CART_ADDR`, `CURRENCY_ADDR`, and four more. Shared
dependencies (the collector reached from 17 services, `flagd` from 12) render one state each,
with no duplicated env vars. Prometheus hands its URL to the collector and to Grafana the same
way, and Grafana hands its address to the proxy.

**The dependant chooses the protocol.** Services export OTLP over gRPC or HTTP. `Collector`
is a parameterized factory: every copy renders the same collector, and only the endpoint it
hands downstream differs.

**SLO fan-out works end to end.** Twelve `RequestObjectives(...)` calls become twelve
dashboards and 72 alert rules without a panel or rule written by hand.

**Platform bugs found and fixed:**
- *Alert rules could never apply.* The Grafana driver rendered `relative_time_range.to = 0`,
  which the compiler drops as a proto3 default, and the provider requires `to`. The test
  stack's golden output had the same defect; nothing had applied it. Now `to = 1`.

**Driver gaps found and closed:** `WithCommand`, `WithMemoryLimit`, `WithPort`,
`WithConfigFiles` and `WithScratchDir` in the Kubernetes driver. All additive; `test/`
output changes only by the alert-range fix above.

**Operational findings:**
- *Chart and repo drift.* The `3.0.0` load generator gates all traffic on a
  `loadGeneratorTraffic` flag that only the chart's flag file defines. With the repo's file
  it ran for half an hour sending nothing, and seven services' SLOs had no data.
- *Empty SDK self-metrics.* Prometheus rejects `otel.sdk.*` instruments with no data points,
  and the collector reported every export as failed. Filtered in the collector.
- *Grafana memory and storage.* Grafana 13 was OOM-killed at 256Mi and 512Mi, and each kill
  wiped the dashboards Terraform had just applied. Now 1Gi with a pod-lifetime scratch dir;
  a pod replacement still needs `make monitoring` afterwards.
- *ConfigMap changes do not roll pods.* After changing a file under `files/`, restart the
  deployment that mounts it.

**Gaps left open:**
- *Addresses that flow up the graph.* The load generator targets `frontend-proxy`, which
  depends on it, so that URL is hand-written. `ForDownstream` only flows down.
- *Config file contents.* Starlark cannot read files, so ConfigMaps use Terraform's `file()`
  and the contents are not in the compiled artifact.
- *Credentials in config.* The demo's published Postgres, flagd-ui and Grafana admin values
  sit in plain env vars in generated Terraform — what DATA-03 exists to prevent.
- *Provider protos per workspace.* Each workspace needs `src/terraform/`; symlinking
  `test/`'s copy is a symptom of the `util.pinc`/proto fork in the deferred list.
- *No readiness ordering.* Services start before the collector and log export timeouts
  until it is up. The platform derives apply order, not health (explicitly out of scope).
- *No namespace.* Everything lands in `default`, next to whatever else is there.
- *Objective history does not survive a redeploy.* Prometheus keeps its data on the pod's
  own disk, so replacing the pod resets every 28-day window. The next burst of errors then
  fills a window of minutes: after one rollout, a single burst of connection failures to a
  restarting product-catalog fired seven burn-rate alerts on frontend and frontend-proxy.
  A PersistentVolumeClaim for Prometheus is the fix.
- *Unexplained lock errors.* The first parallel `make apply` had two runs fail "Error
  acquiring the state lock" on local state, though all 20 state directories are distinct.
  Every state still ended up fully applied, with `terraform plan` clean on all 20.
  `-lock-timeout` now covers it; the cause was not found.
