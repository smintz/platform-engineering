# The OpenTelemetry demo, declared as platform components and applied to a cluster.
# Generated: edit src/otel_demo.mpconf, not outputs/.

# Which domain (CLUSTERS in src/components/defaults.pinc): local, the cluster kubectl points
# at, or gke-<region>, a GKE cluster this stack provisions itself — `make apply
# DOMAIN=gke-asia-southeast3` creates the network and cluster and then deploys onto them.
# Terraform authenticates to GKE out of the cluster's own state; kubectl needs the
# kubeconfig `make credentials` writes, which is what the targets below use.
DOMAIN = local
STATES = outputs/otel_demo/$(DOMAIN)
ORDER = $(STATES)/apply-order.json
CLUSTER = $(STATES)/cluster/infra/main.tf.json
ifneq ($(DOMAIN),local)
export KUBECONFIG := $(HOME)/.kube/otel-demo-$(DOMAIN)
endif
export TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache

# Grafana's API, reached through a port-forward for as long as the monitoring apply runs.
# The provider reads GRAFANA_URL and GRAFANA_AUTH; the password is the demo's local admin.
GRAFANA_PORT = 13000

compile:
	protoconf mod tidy
	protoconf compile .

# The states that other states read go first, in the order apply-order.json gives — on GKE
# the network, then the cluster every other state authenticates against. The rest read
# nothing and go in parallel; a pod whose dependency is not up yet restarts until it is.
# init runs one state at a time because parallel inits race on the plugin cache.
apply: compile
	mkdir -p $(TF_PLUGIN_CACHE_DIR)
	@first=$$(jq -r '.[]' $(ORDER)); \
	for s in $$first; do \
		terraform -chdir=$(STATES)/$$s/infra init -input=false >/dev/null && \
		terraform -chdir=$(STATES)/$$s/infra apply -input=false -auto-approve -lock-timeout=60s || exit 1; \
	done; \
	rest=""; \
	for d in $(STATES)/*/infra; do \
		name=$$(basename $$(dirname $$d)); \
		case " $$first " in *" $$name "*) ;; *) rest="$$rest $$d";; esac; \
	done; \
	for d in $$rest; do terraform -chdir=$$d init -input=false >/dev/null || exit 1; done; \
	echo $$rest | tr ' ' '\n' | grep . | \
		xargs -P 10 -I{} terraform -chdir={} apply -input=false -auto-approve -lock-timeout=60s

# A kubeconfig for the cluster this domain provisioned, for kubectl alone: every Terraform
# state reaches the API server through the credentials the cluster component hands it.
credentials:
	KUBECONFIG=$(KUBECONFIG) gcloud container clusters get-credentials \
		$$(jq -r '.resource.google_container_cluster.cluster.name' $(CLUSTER)) \
		--location $$(jq -r '.resource.google_container_cluster.cluster.location' $(CLUSTER)) \
		--project $$(jq -r '.provider.google[0].project' $(CLUSTER))

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
#
# The reverse of apply: what reads nothing goes first, then the states it read, so the
# cluster outlives everything deployed onto it.
destroy:
	@first=$$(jq -r '.[]' $(ORDER)); \
	rest=""; \
	for d in $(STATES)/*/infra; do \
		name=$$(basename $$(dirname $$d)); \
		case " $$first " in *" $$name "*) ;; *) rest="$$rest $$d";; esac; \
	done; \
	echo $$rest | tr ' ' '\n' | grep . | \
		xargs -P 10 -I{} terraform -chdir={} destroy -input=false -auto-approve -lock-timeout=60s; \
	for s in $$(echo $$first | tr ' ' '\n' | tail -r); do \
		terraform -chdir=$(STATES)/$$s/infra destroy -input=false -auto-approve -lock-timeout=60s || exit 1; \
	done

.PHONY: compile apply credentials monitoring destroy
