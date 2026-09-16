# GKE on the platform

A VPC and a GKE cluster in one GCP project: a workspace that picks the pieces of the
[GKE driver](../../drivers/cluster/gke) it wants and says where they land. The components —
network, subnet, router, NAT, cluster — are the driver's; everything in `src/gke.mpconf` is
this project's own.

The [otel demo](../otel-demo/README.md) builds its own cluster from the same driver and
deploys onto it, which is the other way to use these components. This workspace is the
smaller read: infrastructure and nothing else.

```bash
# once: set PROJECT in src/gke.mpconf, then
gcloud auth application-default login
gcloud components install gke-gcloud-auth-plugin

make bucket        # the GCS bucket every state lives in
make apply         # every state, in the order the graph derives
make credentials   # a kubeconfig for kubectl, at ~/.kube/gke-platform
make destroy
```

Two n4-standard-4 nodes and a Cloud NAT are billed for as long as it runs. Machine families
vary by region: the driver's default `n4-standard-4` has to exist in the zone, and
`asia-southeast3` has no E2 at all —
`gcloud compute machine-types list --zones <zone> --format='value(name)'` says what does.

## What it declares

`src/gke.mpconf` is the whole workspace: the project, the region, the bucket, one subnet,
and the cluster on it.

**A component is not a state.** Only two of these own one. The rest are declared as
dependencies of the network and add their resources to *its* state through `ForDownstream`,
so each piece is written, read and reused separately while still applying as one thing. A
component that writes no config of its own renders no file.

| Component       | What it is                                              | State it lands in |
| --------------- | -------------------------------------------------------- | ----------------- |
| `network`       | the custom-mode VPC, publishing its id                   | `network`         |
| `<name>-subnet` | one subnet with pod and Service ranges                   | `network`         |
| `router`        | a Cloud Router for the network's gateways                | `network`         |
| `nat`           | Cloud NAT: egress for everything with no public address  | `network`         |
| `cluster`       | the zonal GKE cluster and its node pool                  | `cluster`         |

- **Adding a subnet** is one more `gke.Subnet(GCP, name, cidr, pods_cidr, services_cidr)`
  listed in `Network`, and a cluster on it is `gke.Cluster(GCP, Network, that_subnet)`. It
  lands in the network's state beside the first, and the NAT already covers it.
- **Nobody names anybody's address.** The network publishes its id with `WithRemoteOutput`
  and each subnet adds an output for its own; the cluster reads both with `RemoteOutput`,
  through the `terraform_remote_state` that declaring the dependency put in its state.
  Inside one state — a subnet, the router, the NAT — the pieces reference the resources
  directly, because they are written into the same file.
- **The apply order is derived, not declared.** `main()` walks the graph — dependencies
  first — into `outputs/gke/apply-order.json`, which `make apply` follows and `make destroy`
  reverses. Components with no state of their own are left out of it.
- **The cluster**: zonal, with private nodes, Workload Identity and the REGULAR release
  channel. Its node pool runs as a service account holding only
  `roles/container.defaultNodeServiceAccount`. Its nodes are private, so they reach a
  registry only through the NAT — which the network state, applied first, already carries.
- Each state turns on the Google API it uses, and its resources reference that API's
  `project` attribute, so Terraform waits for the API before creating them.
- `deletion_protection = false`, so `make destroy` works.

## Notes

- **`NAME` and the domain are this workspace's own.** The otel demo provisions a cluster
  from the same driver, and two clusters in one project can share neither resource names nor
  a state prefix. This one calls its resources `standalone` and keys its state under
  `standalone-<region>`; the demo's are `platform` and `gke-<region>`. Applying both gives
  two clusters, and two bills.
- **`false` needs proto3 presence.** The provider protos in `src/terraform` are generated
  from `hashicorp/google` 8.2.0, by a `protoconf-terraform` that marks scalar resource
  fields `optional`. Without that, `auto_create_subnetworks = False` and
  `deletion_protection = False` would be dropped from `main.tf.json`, and the provider
  defaults (both `true`) would apply. The tree is pruned with `protoconf-terraform optimize`:
  regenerate it to use a resource that isn't already in it.
- **kubectl needs the kubeconfig; Terraform does not.** `make credentials` writes one for
  the shell. A component that runs *on* the cluster — as the demo's do — is handed the
  endpoint, CA and a token out of the cluster's own state instead, so nothing it applies
  depends on a file on the machine applying it.
