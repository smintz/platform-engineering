# A VPC and a GKE cluster in GCP, a Terraform state each in one GCS bucket. Generated: edit
# src/gke.mpconf, not outputs/. Needs gcloud (with `gcloud auth application-default login`),
# gke-gcloud-auth-plugin and jq.

STATES = outputs/gke/us-central1-a
export TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache

# The kubeconfig `credentials` writes, and the one the otel demo's gke domain applies with.
# Its own file, so neither this nor the demo touches kubectl's current context.
KUBECONFIG_GKE = $(HOME)/.kube/gke-platform

# Everything below reads project, bucket and cluster from the compiled output, so PROJECT in
# src/gke.mpconf is the only place they are written.
NETWORK = $(STATES)/network/infra/main.tf.json
CLUSTER = $(STATES)/cluster/infra/main.tf.json
PROJECT = $$(jq -r '.provider.google[0].project' $(NETWORK))

compile:
	protoconf mod tidy
	protoconf compile .

# The state bucket has to exist before any state can be written to it.
bucket: compile
	gcloud storage buckets create gs://$$(jq -r '.terraform.backend.gcs.bucket' $(NETWORK)) \
		--project $(PROJECT) --location $$(jq -r '.provider.google[0].region' $(NETWORK)) \
		--uniform-bucket-level-access

# network before cluster: the cluster reads the network's state.
apply: compile
	mkdir -p $(TF_PLUGIN_CACHE_DIR)
	for s in network cluster; do \
		terraform -chdir=$(STATES)/$$s/infra init -input=false >/dev/null && \
		terraform -chdir=$(STATES)/$$s/infra apply -input=false -auto-approve || exit 1; \
	done

credentials:
	KUBECONFIG=$(KUBECONFIG_GKE) gcloud container clusters get-credentials \
		$$(jq -r '.resource.google_container_cluster.cluster.name' $(CLUSTER)) \
		--location $$(jq -r '.resource.google_container_cluster.cluster.location' $(CLUSTER)) \
		--project $(PROJECT)

destroy:
	for s in cluster network; do \
		terraform -chdir=$(STATES)/$$s/infra init -input=false >/dev/null && \
		terraform -chdir=$(STATES)/$$s/infra destroy -input=false -auto-approve || exit 1; \
	done

.PHONY: compile bucket apply credentials destroy
