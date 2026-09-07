# External Integrations

**Analysis Date:** 2026-09-07

Nothing in this repo talks to a network at compile time. Every integration below is a
*generated* one: Terraform providers, backends and CI steps that the compiled output uses
at apply time. Read each entry as "what the emitted config connects to".

## APIs & External Services

**Monitoring (Grafana):**
- Grafana (self-hosted or Amazon Managed Grafana) — dashboards, alert folders and alert
  rule groups per component
  - Driver: `drivers/monitoring/grafana/src/grafana.pinc`, rules in
    `drivers/monitoring/grafana/src/grafana/alerts.pinc`
  - Terraform provider: `grafana/grafana` 4.45.2 (`.terraform.lock.hcl`, `providers.tf`)
  - Resources emitted: `grafana_dashboard`, `grafana_folder`, `grafana_rule_group`;
    datasource uid resolved at apply time via the `grafana_data_source` data source
  - Auth: `GRAFANA_URL` + `GRAFANA_AUTH` env vars, exported into `$GITHUB_ENV` by the
    `grafana-token` CI step (`GRAFANA_TOKEN_SCRIPT` in
    `drivers/cicd/github_actions/src/github_actions.pinc`)
  - Panel/dashboard schema is proto-typed in
    `drivers/monitoring/grafana/src/grafana/v1/dashboard.proto` (schemaVersion 39)

**Metrics backends queried by SLOs/dashboards:**
- Prometheus — the default `datasource` on `WithSLO`/`WithDiagnostic`
  (`src/platform/monitoring.pinc`). Reference queries live in `test/src/core_test.mpconf`
  (`http_requests_total`, `http_request_duration_seconds_*`, `redis_up`,
  `kube_pod_container_status_restarts_total`, `redis_memory_used_bytes`).
- AWS CloudWatch — Metrics Insights SQL in `sqlExpression`, handled in `target()` in
  `drivers/monitoring/grafana/src/grafana.pinc` (`CLOUDWATCH`)
- Postgres — raw SQL targets, same file (`POSTGRES`)
- Datasource *names* are the organisation's, mapped in the `.mpconf`
  (`DATASOURCES = {"prometheus": "Prometheus"}` in `test/src/core_test.mpconf`)

**Container runtimes:**
- Kubernetes — `kubernetes_deployment` + ClusterIP `kubernetes_service` per workload
  - Driver: `drivers/runtime/kubernetes/src/kubernetes.pinc`
  - Provider: `hashicorp/kubernetes` 3.2.1, pointed at `~/.kube/config` by default
    (`KUBECONFIG`, `KubeConfig(context=..., path=...)`); unset `config_context` means the
    kubeconfig's current-context
- AWS ECS — task definitions, services and IAM role policy attachments
  - Driver: `drivers/runtime/ecs/src/ecs.pinc`, helpers in
    `drivers/runtime/ecs/src/lib/ecs/ecs.pinc`
  - Schema: `drivers/runtime/ecs/src/aws/ecs/v1/taskdefinition.proto`
  - Uses `terraform/aws/resources/v5/iam.proto`; CloudWatch Logs via the container's
    `awslogs-*` log configuration options
  - Cluster, subnets and log group are deliberately *not* provisioned here — they are
    caller-supplied data sources

**Container registries (referenced by generated workloads):**
- `ghcr.io` and Docker Hub images appear only as example values in
  `test/src/core_test.mpconf` (`ghcr.io/example/api:latest`, `redis:7-alpine`)

## Data Storage

**Terraform state backends** (`drivers/state/terraform/src/terraform.pinc`):
- `LocalBackend` — the default; `terraform.tfstate` next to the config unless `path_for`
  is given. Cross-state reads fail loudly rather than guessing a path.
- `S3Backend(bucket, region, key_for)` — what the reference stack uses:
  bucket `platform-engineering-tfstate`, region `us-east-1`, key
  `<domain>/<name>.tfstate` (`test/src/core_test.mpconf`)
- `GCSBackend(bucket, key_for)` — Google Cloud Storage
- `AzureRMBackend(storage_account_name, container_name, key_for)` — Azure Blob Storage
- `RemoteBackend(organization, key_for, hostname="")` — Terraform Cloud / Enterprise
- Cross-state reads go through the `terraform_remote_state` data source
  (`terraform/builtin/datasources/v1/remote_state.proto`); the same backend description
  produces both the writer's `backend` block and the reader's config, so the two cannot
  disagree.

**Application data stores (in the reference stack only):**
- Redis (`redis:7-alpine`) as a component, addressed by its Kubernetes Service name; its
  URL is handed downstream as `REDIS_URL=redis://redis:6379`

**File Storage:**
- None beyond the state buckets above. Compiler artifacts are on local disk:
  `materialized_config/**/*.materialized_JSON` and `outputs/**` (and their `test/`
  equivalents).

**Caching:**
- None in the product. CI caches Terraform plugins at
  `/home/runner/.terraform.d/plugin-cache` via `actions/cache@v4`.

## Authentication & Identity

**AWS (Terraform + Grafana token minting):**
- `OidcCredentials(region, plan_role=..., apply_role=...)` — GitHub OIDC traded for an IAM
  role by `aws-actions/configure-aws-credentials@v4`; roles default to
  `${{ vars.TF_PLAN_ROLE }}` and `${{ vars.TF_APPLY_ROLE }}`. Separate read-only plan role
  and writing apply role.
- Static keys are supported as a fallback: `${{ secrets.AWS_ACCESS_KEY_ID }}` /
  `${{ secrets.AWS_SECRET_ACCESS_KEY }}`
  (`drivers/cicd/github_actions/src/github_actions.pinc`)

**Grafana:**
- `GrafanaServiceAccountToken(credentials, workspace, plan_account, apply_account,
  seconds_to_live=1800)` mints a short-lived Amazon Managed Grafana workspace service
  account token per job, masks it, and exports `GRAFANA_AUTH`/`GRAFANA_URL`. It also reaps
  expired tokens on the account. Only jobs whose config declares the Grafana provider get
  the step.
- Required IAM actions (documented in that file): `grafana:ListWorkspaceServiceAccounts`,
  `grafana:ListWorkspaceServiceAccountTokens`, `grafana:CreateWorkspaceServiceAccountToken`,
  `grafana:DeleteWorkspaceServiceAccountToken`, `grafana:DescribeWorkspace`.
- Workspace id comes from `${{ vars.GRAFANA_WORKSPACE_ID }}`; accounts
  `protoconf-plan` / `protoconf-apply` (`test/src/core_test.mpconf`).

**Kubernetes:**
- Whatever the kubeconfig holds, or in-cluster credentials when an all-default
  `Kubernetes()` provider is passed to `Workload(...)`.

## Monitoring & Observability

**Dashboards:** one Grafana dashboard per component, rendered in a `Finally` hook from the
objectives recorded on the component — SLO stat panels, an upstream alert list, diagnostic
timeseries (`drivers/monitoring/grafana/src/grafana.pinc`).

**Alerting:** multiwindow multi-burn-rate `grafana_rule_group` rules generated from each
SLO's `burn_query` (`BURN_RATES` in `drivers/monitoring/grafana/src/grafana/alerts.pinc`:
fast burn 1h/5m ×14.4 → page, slow burn 6h/30m ×6.0). Threshold alerts are the fallback
for objectives with no error budget (`threshold_alert` in `src/platform/v1/platform.proto`).

**Error Tracking:** none.

**Logs:** ECS containers ship to CloudWatch Logs via `awslogs-*` options
(`drivers/runtime/ecs/src/ecs.pinc`); nothing configured for Kubernetes.

**Monitoring state isolation:** monitoring resources live in their own Terraform state,
`monitoring/main.tf.json` with a `-monitoring` state-name suffix
(`MONITORING_CONFIG`/`MONITORING_SUFFIX` in `src/platform/monitoring.pinc`), so a broken
dashboard cannot block an infrastructure apply.

## CI/CD & Deployment

**CI Pipeline:** GitHub Actions, fully generated —
`actions.TerraformPipeline(configs, OUTPUT_ROOT, credentials)` in
`drivers/cicd/github_actions/src/github_actions.pinc`, emitted to
`test/outputs/core_test/.github/workflows/terraform.yaml` and installed to
`.github/workflows/terraform.yaml` by `test/Makefile`. Do not edit the YAML.
- Runner: `ubuntu-latest` (`drivers/cicd/github_actions/src/github/lib.pinc`)
- Terraform 1.9.8 via `hashicorp/setup-terraform@v3`; `LOCK_TIMEOUT = "5m"`
- Plan on pull requests, apply on `main`; job order is *derived* by matching each config's
  backend key against every `terraform_remote_state` config key (`_backend_state_id` /
  `_remote_state_id`)
- Actions used: `actions/checkout@v4`, `actions/cache@v4`,
  `actions/upload-artifact@v4`, `actions/download-artifact@v4`,
  `actions/github-script@v7`, `aws-actions/configure-aws-credentials@v4`
- Workflow permissions: `id-token: write` (OIDC), `pull-requests: write` (plan comment)
- Workflow schema is proto-typed: `drivers/cicd/github_actions/src/github/actions.proto`

**Hosting:** the platform itself is not deployed; it emits Terraform that deploys others.

## Environment Configuration

**GitHub repository variables:**
- `TF_PLAN_ROLE`, `TF_APPLY_ROLE` — IAM roles assumed via OIDC
- `GRAFANA_WORKSPACE_ID` — Amazon Managed Grafana workspace

**GitHub repository secrets (fallback path only):**
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

**Job-scoped env exported at runtime:**
- `GRAFANA_AUTH`, `GRAFANA_URL` (masked, TTL 1800s by default)

**Secrets location:** GitHub Actions vars/secrets and AWS IAM. No `.env` file exists in
this repo, and `.gitignore` excludes `*.tfvars`, `*.tfstate*` and `.terraform/`.

## Webhooks & Callbacks

**Incoming:** GitHub `pull_request` and `push`-to-`main` events driving the generated
workflow. No application webhook endpoints.

**Outgoing:** the plan-comment job posts back to the pull request through
`actions/github-script@v7` — one comment per run, not per state. Grafana notification
policies / contact points are not yet generated (PagerDuty and Discord are named as future
providers in `src/platform/monitoring.pinc`).

---

*Integration audit: 2026-09-07*
