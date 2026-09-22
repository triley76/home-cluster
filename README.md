# home-cluster

GitOps configuration for an evolving Kubernetes platform spanning a self-managed K3s homelab and planned managed-cloud environments.

This repository is the desired-state layer of the broader **Enterprise Platform & AI Engineering Lab**. Infrastructure provisioning for the VMware/K3s environment is maintained separately in [homelab-k3s](https://github.com/triley76/homelab-k3s).

## Current status

The active V2 baseline has been intentionally reduced to safe reconciliation while platform services are redesigned and validated.

### Implemented and validated

- Flux 2.9.5 controllers installed and healthy.
- GitRepository and Kustomization reconciliation from `feature/v2-cluster`.
- Root reconciliation of `clusters/home`.
- Empty infrastructure and application resource lists used as a safe V2 baseline.
- Structural Kustomize rendering of the baseline.

### Present but not enabled

The repository contains earlier manifests for:

- MetalLB
- Traefik service configuration
- Longhorn
- An echo test workload

These manifests are retained for review but are excluded from active reconciliation. Their presence does not mean the associated services are deployed or validated on V2.

### Planned

- Explicit ingress-controller selection and validation.
- Deliberate persistent-storage design.
- Observability and backup/restore.
- Hardened canary workload.
- Platform-specific GitOps overlays for K3s, Azure Kubernetes Service (AKS), and Amazon Elastic Kubernetes Service (EKS).
- Terraform-managed cloud infrastructure.
- Application and AIStudio workload integration.

## Repository structure

```text
clusters/
└── home/
    ├── flux-system/       # Flux-generated controllers and synchronization
    ├── infrastructure/    # Platform services; currently disabled
    ├── apps/              # Workloads; currently disabled
    └── kustomization.yaml # Cluster reconciliation root
```

The structure will evolve as K3s, AKS, and EKS environments are implemented. Shared resources will be separated from environment-specific networking, ingress, storage, and cloud integrations.

## Validation boundaries

The VMware/K3s platform has separately demonstrated three-node embedded-etcd operation, kube-vip API failover during one tested node outage, workload rescheduling, and node reintegration.

That testing does not establish:

- Measured zero-downtime failover
- Two-node or multi-node failure tolerance
- Production readiness
- Persistent-storage recovery
- Completed AKS or EKS implementations
- Deployment of the dormant platform-service manifests in this repository

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
