# ARO HCP

Creates an Azure Red Hat OpenShift hosted control plane in West Europe.

The cluster has a private API, a public console, and two `Standard_D8s_v3` workers. etcd is encrypted with a customer-managed key. The account that runs the deploy is granted `cluster-admin` through Microsoft Entra ID, and the cluster receives a Red Hat pull secret. OpenShift Virtualization is not installed.

## Prerequisites

- `az login` against the subscription that should own the cluster
- The [ARO HCP CLI extension](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster?pivots=aro-az-cli#aro-hcp-cli-extension)
- Permission to create Entra app registrations in that tenant
- A Red Hat pull secret containing `registry.redhat.io` and `registry.connect.redhat.com`

The pull secret is read from `~/pull_secret.json`. Override the path with `PULL_SECRET_FILE`. It is not written into this repository.

## Use

```bash
make deploy
make status
make delete CONFIRM=yes
```

`make deploy` can be run again. It leaves existing infrastructure in place and finishes any step that did not complete.

`make status` prints the cluster state, the worker pool, and the console URL.

Sign in to that URL with the same Microsoft account that ran `make deploy`. There is no kubeadmin password. The API stays on the private network, so `oc` from this machine cannot reach it.

`make delete CONFIRM=yes` deletes the cluster, both resource groups, the soft-deleted Key Vault, and the Entra applications.

## What gets created

| Piece | Name |
|---|---|
| Region | `westeurope` |
| Cluster | `aro-hcp-weu`, OpenShift 4.22 |
| Workers | `workers`, 2 × `Standard_D8s_v3`, 4.22.15 |
| API / ingress | Private / Public |
| Entra apps | `aro-hcp-weu-console`, `aro-hcp-weu-cli` |
| Pull secret | `registry.redhat.io`, `registry.connect.redhat.com`, and `quay.io` when present |

Deploy opens a temporary jump box to reach the private API, applies the pull secret and the console client secret, then deletes the jump box. The jump box has no inbound rules.

`state/cluster.env` is generated locally and is gitignored. Do not commit it.

## Layout

```
Makefile
README.md
scripts/deploy.sh
scripts/delete.sh
scripts/status.sh
scripts/lib/
state/cluster.env
```

`az` comes from the system path, including the `aro-hcp` extension. `scripts/lib/` holds the network, cluster, jump box, and console steps. The three scripts next to it are the ones the Makefile runs.
