# GKE on the platform

A VPC and a GKE cluster in one GCP project, declared as two platform components with a
Terraform state each: the cluster the [otel demo](../otel-demo/README.md) deploys onto with
`DOMAIN=gke`.

```bash
# once: set PROJECT in src/gke.mpconf, then
gcloud auth application-default login
gcloud components install gke-gcloud-auth-plugin

make bucket        # the GCS bucket every state lives in
make apply         # network, then cluster
make credentials   # writes ~/.kube/gke-platform

cd ../otel-demo
make apply monitoring DOMAIN=gke
KUBECONFIG=~/.kube/gke-platform kubectl port-forward svc/frontend-proxy 8080:8080

make destroy DOMAIN=gke          # the demo first: its states need the cluster
cd ../gke && make destroy
```

Two e2-standard-4 nodes and a Cloud NAT are billed for as long as it runs.

## What it declares

Everything is in `src/gke.mpconf`.

- **network**: a custom-mode VPC with one subnet. Nodes use `10.0.0.0/20`, pods `10.4.0.0/14`
  and Services `10.8.0.0/20`. Cloud NAT lets private nodes pull the demo's images from
  ghcr.io. It publishes `network` and `subnetwork` with `WithRemoteOutput`.
- **cluster**: zonal (`us-central1-a`), with private nodes, Workload Identity and the
  REGULAR release channel. Its one node pool runs as a service account holding only
  `roles/container.defaultNodeServiceAccount`. `WithDeps(NetworkComponent)` gives it a
  `terraform_remote_state` read of the network's state, so it never names the network.
- Each state turns on the Google API it uses, and its resources reference that API's
  `project` attribute, so Terraform waits for the API before creating them.
- `deletion_protection = false`, so `make destroy` works.

## Notes

- **`false` needs proto3 presence.** The provider protos in `src/terraform` are generated
  from `hashicorp/google` 8.2.0, by a `protoconf-terraform` that marks scalar resource
  fields `optional`. Without that, `auto_create_subnetworks = False` and
  `deletion_protection = False` would be dropped from `main.tf.json`, and the provider
  defaults (both `true`) would apply. The tree is pruned with `protoconf-terraform optimize`:
  regenerate it to use a resource that isn't already in it.
- **The demo reaches the cluster through a kubeconfig, not this state.** The cluster lives
  in another workspace, so there is no graph edge to hand its address down. The demo's
  `CLUSTERS` in `components/defaults.pinc` points the `gke` domain at the file that
  `make credentials` writes, and never uses kubectl's current context.
