# OpenTelemetry demo on the platform

The [OpenTelemetry demo](https://github.com/open-telemetry/opentelemetry-demo)'s 20 core
services (`compose.yaml`) declared as platform components and applied to a local cluster.
An exercise in how the platform's practices hold up against a real, dependency-heavy stack.

```bash
make compile   # src/otel_demo.mpconf -> outputs/otel_demo/colima/<service>/infra/main.tf.json
make apply     # one local-state Terraform apply per service, against kubectl's current context
make destroy
kubectl port-forward svc/frontend-proxy 8080:8080   # storefront at http://localhost:8080
```

Sized for about 3 GiB of memory limits; a Colima VM with 4+ CPU and 8+ GiB is comfortable.

## Where things come from

- **Services and dependency edges:** the demo's `compose.yaml` (`depends_on`).
- **Images, ports, memory, environment:** its Helm chart (demo `3.0.0`), the demo's own
  description of running these images on Kubernetes.
- **`files/`:** `demo.flagd.json`, `init.sql` and `otel-config.yml` copied from the demo.
  `otelcol-config.yml` is new: a minimal OTLP-in, debug-out collector, since the upstream
  config expects Docker, host metrics and a Jaeger/Prometheus/OpenSearch backend.
- **`src/terraform`:** a symlink to `test/src/terraform`, the vendored provider protos.

## What the exercise showed

**Dependency wiring fans out as designed.** No service writes another service's address.
Each service declares `WithDeps(...)`, and each dependency hands its own address downstream
with `ForDownstream`: `checkout` gets `CART_ADDR`, `CURRENCY_ADDR`, and four more. Shared
dependencies (the collector reached from 17 services, `flagd` from 12) render one state each,
with no duplicated env vars.

**The dependant chooses the protocol.** Services export OTLP over gRPC or HTTP. `Collector`
is a parameterized factory: every copy renders the same collector, and only the endpoint it
hands downstream differs.

**Gaps found and closed in the Kubernetes driver:** `WithCommand`, `WithMemoryLimit`,
`WithPort` (a named second port) and `WithConfigFiles` (ConfigMap plus mount). All
additive; `test/` compiles byte-identical.

**Gaps found and left open:**
- *Addresses that flow up the graph.* The load generator targets `frontend-proxy`, which
  depends on it, so that URL is hand-written. `ForDownstream` only flows down.
- *Config file contents.* Starlark cannot read files, so ConfigMaps use Terraform's `file()`
  and the contents are not in the compiled artifact.
- *Credentials in config.* The demo's published Postgres and flagd-ui secrets sit in plain
  env vars in generated Terraform — what DATA-03 exists to prevent.
- *Provider protos per workspace.* Each workspace needs `src/terraform/`; symlinking
  `test/`'s copy is a symptom of the `util.pinc`/proto fork in the deferred list.
- *No readiness ordering.* Services start before the collector and log export timeouts
  until it is up. Kubernetes restarts converge it; the platform derives apply order, not
  health (explicitly out of scope).
- *No namespace.* Everything lands in `default`, next to whatever else is there.
- *Unexplained lock errors.* The first parallel `make apply` had two runs fail "Error
  acquiring the state lock" on local state, though all 20 state directories are distinct.
  Every state still ended up fully applied, with `terraform plan` clean on all 20.
  `-lock-timeout` now covers it; the cause was not found.
