# The OpenTelemetry demo, declared as platform components and applied to the local
# cluster kubectl points at. Generated: edit src/otel_demo.mpconf, not outputs/.

STATES = outputs/otel_demo/colima
export TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache

# Grafana's API, reached through a port-forward for as long as the monitoring apply runs.
# The provider reads GRAFANA_URL and GRAFANA_AUTH; the password is the demo's local admin.
GRAFANA_PORT = 13000

compile:
	protoconf mod tidy
	protoconf compile .

# One state per component, as the platform renders them. There is no apply order to honour:
# nothing here reads another state, and a pod whose dependency is not up yet restarts until
# it is. init runs one state at a time because parallel inits race on the plugin cache.
apply: compile
	mkdir -p $(TF_PLUGIN_CACHE_DIR)
	for d in $(STATES)/*/infra; do terraform -chdir=$$d init -input=false >/dev/null || exit 1; done
	ls -d $(STATES)/*/infra | xargs -P 10 -I{} terraform -chdir={} apply -input=false -auto-approve -lock-timeout=60s

# The monitoring states talk to Grafana rather than to the cluster, so they wait for the
# infra states that deploy it: dashboards and alert rules for every component that
# declared objectives.
monitoring:
	kubectl rollout status deploy/grafana --timeout=120s
	for d in $(STATES)/*/monitoring; do terraform -chdir=$$d init -input=false >/dev/null || exit 1; done
	kubectl port-forward svc/grafana $(GRAFANA_PORT):3000 >/dev/null & pf=$$!; \
	trap "kill $$pf" EXIT; \
	for i in $$(seq 30); do curl -sf http://127.0.0.1:$(GRAFANA_PORT)/grafana/api/health >/dev/null && break; sleep 1; done; \
	ls -d $(STATES)/*/monitoring | GRAFANA_URL=http://127.0.0.1:$(GRAFANA_PORT)/grafana GRAFANA_AUTH=admin:admin \
		xargs -P 4 -I{} terraform -chdir={} apply -input=false -auto-approve -lock-timeout=60s
# -P 4, not 10: every monitoring state writes to the same Grafana, whose SQLite database
# serialises writers — ten at once filled its log with SQLITE_BUSY retries and spiked its
# memory while it was already close to its limit.

# -lock-timeout: the first parallel apply had two runs fail "Error acquiring the state lock"
# on local state even though every state directory is distinct; the cause was not pinned
# down, and waiting for the lock is correct whatever it is.
destroy:
	ls -d $(STATES)/*/infra | xargs -P 10 -I{} terraform -chdir={} destroy -input=false -auto-approve -lock-timeout=60s

.PHONY: compile apply monitoring destroy
