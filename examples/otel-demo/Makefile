# The OpenTelemetry demo, declared as platform components and applied to the local
# cluster kubectl points at. Generated: edit src/otel_demo.mpconf, not outputs/.

STATES = outputs/otel_demo/colima
export TF_PLUGIN_CACHE_DIR := $(HOME)/.terraform.d/plugin-cache

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

# -lock-timeout: the first parallel apply had two runs fail "Error acquiring the state lock"
# on local state even though every state directory is distinct; the cause was not pinned
# down, and waiting for the lock is correct whatever it is.
destroy:
	ls -d $(STATES)/*/infra | xargs -P 10 -I{} terraform -chdir={} destroy -input=false -auto-approve -lock-timeout=60s

.PHONY: compile apply destroy
