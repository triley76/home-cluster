# home-cluster

GitOps configuration for an evolving Kubernetes platform spanning a self-managed K3s homelab and planned managed-cloud environments.

This repository is the desired-state layer of the broader **Enterprise Platform & AI Engineering Lab**. Infrastructure provisioning for the VMware/K3s environment is maintained separately in [homelab-k3s](https://github.com/triley76/homelab-k3s).

## Current status

The active V2 environment now includes a deliberately introduced networking service and hardened validation workload. Additional platform services remain disabled until they are reviewed and tested individually.

### Implemented and validated

- Flux 2.9.5 controllers installed and healthy.
- GitRepository and Kustomization reconciliation from `feature/v2-cluster`.
- Root reconciliation of `clusters/home`.
- MetalLB 0.16.1 installed through a Flux-managed HelmRelease.
- MetalLB configured for L2 advertisement on `ens160`, without the unnecessary FRR-K8s backend.
- Address pool `10.0.0.220-10.0.0.230` configured outside the router's DHCP scope.
- Hardened two-replica canary workload exposed through a LoadBalancer service at `10.0.0.220`.
- LAN reachability and traffic distribution across both canary replicas.
- MetalLB advertisement migration during one tested announcer-node outage.
- Node recovery, speaker reintegration, endpoint restoration, and return of L2 ownership.

See [MetalLB L2 validation](docs/validation/metallb-l2.md) for the observed test evidence and its limits.

### Present but not enabled

The repository contains an earlier Longhorn manifest retained for review but excluded from active reconciliation. Its presence does not mean persistent storage is deployed or validated on V2.

The obsolete V1 Traefik service patch has been removed; ingress selection and deployment remain planned.

### Planned

- Explicit ingress-controller selection and validation.
- Deliberate persistent-storage design.
- Observability and backup/restore.
- Platform-specific GitOps overlays for K3s, Azure Kubernetes Service (AKS), and Amazon Elastic Kubernetes Service (EKS).
- Terraform-managed cloud infrastructure.
- Application and AIStudio workload integration.

## Repository structure

```text
clusters/
└── home/
    ├── flux-system/       # Flux-generated controllers and synchronization
    ├── infrastructure/    # Platform services introduced incrementally
    ├── apps/              # Validated and planned workloads
    └── kustomization.yaml # Cluster reconciliation root
```

The structure will evolve as K3s, AKS, and EKS environments are implemented. Shared resources will be separated from environment-specific networking, ingress, storage, and cloud integrations.

## Validation boundaries

The VMware/K3s platform has demonstrated three-node embedded-etcd operation, kube-vip API failover during one tested node outage, MetalLB L2 advertisement migration during one tested announcer-node outage, post-failover workload availability through a surviving replica, and node reintegration.

That testing does not establish:

- Measured zero-downtime failover
- Two-node or multi-node failure tolerance
- Production readiness
- Persistent-storage recovery
- Completed AKS or EKS implementations
- Completed ingress, observability, or backup services
- Validation of Longhorn

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
