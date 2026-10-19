# home-cluster

GitOps configuration for an evolving Kubernetes platform spanning a self-managed K3s homelab and planned managed-cloud environments.

This repository is the desired-state layer of the broader **Enterprise Platform & AI Engineering Lab**. Infrastructure provisioning for the VMware/K3s environment is maintained separately in [homelab-k3s](https://github.com/triley76/homelab-k3s).

## Current status

The active V2 environment includes a deliberately introduced networking service and hardened validation workload. Additional platform services will be added only after they are reviewed and tested individually.

### Implemented and validated

- Flux 2.9.5 controllers installed and healthy.
- GitRepository and Kustomization reconciliation from `main`.
- Root reconciliation of `clusters/home`.
- MetalLB 0.16.1 installed through a Flux-managed HelmRelease.
- MetalLB configured for L2 advertisement on `ens160`, without the unnecessary FRR-K8s backend.
- Address pool `10.0.0.220-10.0.0.230` configured outside the router's DHCP scope.
- Hardened two-replica canary workload exposed through a LoadBalancer service at `10.0.0.220`.
- LAN reachability and traffic distribution across both canary replicas.
- MetalLB advertisement migration during one tested announcer-node outage.
- Node recovery, speaker reintegration, endpoint restoration, and return of L2 ownership.
- Layered Flux reconciliation with `dependsOn`, so MetalLB CRDs exist before MetalLB configuration is applied:
  - `infrastructure-controllers`
  - `infrastructure-configs`
  - `apps`
- Flux self-management of `clusters/home/flux-system` from the root Kustomization.
- Ownership transfer of seven live objects to the child Kustomizations with unchanged UIDs and no Helm upgrade.
- Normal Flux garbage-collection semantics after the temporary migration protections were removed.
- A monitoring layer (`monitoring`, `monitoring-configs`) reconciled after `infrastructure-configs`, independent of `apps`: kube-prometheus-stack 91.8.2 with Prometheus, Alertmanager, kube-state-metrics and node-exporter.
- Grafana, internal only through a `ClusterIP` Service: `restricted` Pod Security, a ConfigMap-only Role, admin credentials from an out-of-band Secret that is not in Git, and a 1 GiB `local-path` claim. It was validated by exact-commit k3d clean-bootstrap and upgrade rehearsals and by the live rollout.
- Stage 1 of the backup design, the AWS foundation only: a private, versioned, SSE-S3 bucket in `us-east-1`, two prefix-scoped machine IAM users with no access keys, and a routine `HomeClusterBackupOperator` IAM Identity Center permission set. Stage 1 itself uploaded no backup data and performed no restore rehearsal.
- Stage 2 of the backup design, encrypted recovery material: the K3s server token, the Grafana admin credential and a recovery inventory, each encrypted client-side with a pinned `age` v1.3.2, uploaded with the routine role, downloaded by exact version and verified against its source, and the inventory held on two offline recovery drives. A cluster incident during this stage was resolved by a local etcd snapshot restore, validated on all three nodes; its root cause was not determined. No restore from the uploaded material has been rehearsed.

See [MetalLB L2 validation](docs/validation/metallb-l2.md), [Flux reconciliation-split validation](docs/validation/flux-reconciliation-split.md), [observability validation](docs/validation/observability.md), [AWS backup foundation validation](docs/validation/aws-backup-foundation.md) and [encrypted recovery material validation](docs/validation/encrypted-recovery-material.md) for the observed test evidence and its limits.


### Planned

- Explicit ingress-controller selection and validation.
- Deliberate persistent-storage design.
- Remaining observability work: Flux and MetalLB scrape targets, platform alert rules and dashboards, and alert delivery.
- Backup/restore beyond Stages 1 and 2: secrets encryption at rest, machine credentials, etcd and volume uploads, and restore rehearsals.
- Platform-specific GitOps overlays for K3s, Azure Kubernetes Service (AKS), and Amazon Elastic Kubernetes Service (EKS).
- Terraform-managed cloud infrastructure.
- Application and AIStudio workload integration.

## Repository structure

```text
clusters/
└── home/
    ├── kustomization.yaml      # Root: flux-system, infrastructure.yaml, apps.yaml, monitoring.yaml
    ├── flux-system/            # Flux-generated controllers and synchronization (self-managed)
    ├── infrastructure.yaml     # Flux Kustomizations: infrastructure-controllers, infrastructure-configs
    ├── apps.yaml               # Flux Kustomization: apps (depends on infrastructure-configs)
    ├── monitoring.yaml         # Flux Kustomizations: monitoring (depends on infrastructure-configs), monitoring-configs
    ├── infrastructure/
    │   ├── controllers/        # MetalLB HelmRepository and HelmRelease
    │   └── configs/            # MetalLB IPAddressPool and L2Advertisement
    ├── apps/                   # Validated workloads
    └── monitoring/
        ├── controllers/        # Namespaces, kube-prometheus-stack HelmRepository and HelmRelease, Grafana Role
        └── configs/            # Empty until observability Phase 4
```

Reconciliation order: `flux-system` → `infrastructure-controllers` → `infrastructure-configs`, then `apps` and `monitoring` → `monitoring-configs` as independent branches. See the [reconciliation-split design](docs/design/flux-reconciliation-split.md) and the [observability design](docs/design/observability.md).

The structure will evolve as K3s, AKS, and EKS environments are implemented. Shared resources will be separated from environment-specific networking, ingress, storage, and cloud integrations.

## Validation boundaries

The VMware/K3s platform has demonstrated:

- three-node embedded-etcd operation;
- kube-vip API failover during one tested node outage;
- MetalLB L2 advertisement migration during one tested announcer-node outage;
- post-failover workload availability through a surviving replica;
- node reintegration.

The Flux reconciliation split was applied in place. No interruption was observed during the Phase 3 migration window, at the LAN monitor's sample rate. The later Phase 4 monitor recorded failures during an unrelated host reboot, as described in the validation record. Clean-bootstrap ordering was tested in k3d only.

Grafana's clean bootstrap and upgrade were rehearsed in single-node k3d. After the live rollout, no interruption was observed within two separate one-hour windows (a Windows LAN canary monitor and a Linux cluster and Grafana monitor), each at its own sample rate.

That testing does not establish:

- Measured zero-downtime failover
- Zero-downtime behavior outside the monitored windows
- A clean bootstrap of the VMware/K3s cluster
- Two-node or multi-node failure tolerance
- Production readiness
- Persistent-storage recovery, including Grafana's node-local `local-path` volume
- Highly available or multi-node Grafana, or encrypted external access to it
- Completed AKS or EKS implementations
- Completed ingress or backup services, or the remaining observability work (Flux and MetalLB scrape targets, platform alerts, alert delivery)

Claims in this repository are updated only after implementation and validation evidence exists.

## Secrets policy

Plaintext credentials, private keys, kubeconfigs, tokens, and Kubernetes Secret values must not be committed.

Environment-specific secrets will use an approved encrypted or external secret-management workflow before applications requiring credentials are enabled. See [SECURITY.md](SECURITY.md).

## Development workflow

Changes are introduced incrementally:

1. Preserve a recovery checkpoint.
2. Render and review manifests.
3. Commit the smallest coherent change.
4. Allow Flux to reconcile.
5. Validate the resulting cluster state.
6. Record exactly what the evidence supports.

## Relationship to homelab-k3s

- `homelab-k3s`: image construction, VM provisioning, operating-system configuration, K3s bootstrap, kube-vip, and infrastructure validation.
- `home-cluster`: Flux reconciliation, platform services, and applications.

This separation keeps infrastructure creation distinct from ongoing declarative cluster state.
