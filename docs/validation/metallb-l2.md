# MetalLB L2 validation

## Scope

This record documents validation performed on the three-node V2 K3s cluster on September 22, 2026.

The test covered:

- Flux deployment of MetalLB
- L2 address allocation and advertisement
- LAN access to a LoadBalancer service
- Distribution across two workload replicas
- Failure of the node initially advertising the service address
- Recovery and reintegration of that node

This was a single-node failure test. It was not a production-readiness or multi-node failure test.

## Configuration under test

| Component | Configuration |
| --- | --- |
| Kubernetes | K3s v1.36.4+k3s1 |
| Cluster | Three control-plane/etcd nodes |
| MetalLB | Helm chart 0.16.1 |
| Advertisement mode | L2 |
| Node interface | `ens160` |
| Address pool | `10.0.0.220-10.0.0.230` |
| Test service address | `10.0.0.220` |
| Test workload | Two hardened `platform-canary` replicas |

FRR-K8s was disabled because the tested configuration uses L2 advertisement rather than BGP.

## Baseline validation

Flux reported the GitRepository and root Kustomization ready at the expected Git revision. The MetalLB HelmRelease reported ready after installing chart 0.16.1.

The resulting MetalLB deployment contained:

- One healthy controller
- One healthy speaker on each of the three nodes
- One `IPAddressPool` named `home-pool`
- One `L2Advertisement` named `home-l2`

The `platform-canary` deployment reported two available replicas, scheduled on `k3s02` and `k3s03`. Its LoadBalancer service received `10.0.0.220`, and its EndpointSlice contained both pod addresses.

## LAN and distribution validation

Requests from a Windows workstation on the LAN successfully reached `http://10.0.0.220/`.

Repeated requests returned hostnames from both canary replicas. This demonstrated:

- Reachability of the MetalLB-assigned address from outside the cluster
- Successful routing to the service endpoints
- Traffic distribution across both available replicas

The Windows ARP table resolved `10.0.0.220` to the MAC address of the node advertising the service.

## Single-node failure validation

Before the test, MetalLB reported `k3s02` as the allocated L2 advertisement node. The `k3s02` virtual machine was then powered off.

Observed results:

- Kubernetes reported `k3s02` as `NotReady`.
- MetalLB moved L2 advertisement ownership to `k3s01`.
- The workstation ARP entry changed to the MAC address associated with `k3s01`.
- The canary replica on `k3s03` remained available.
- Requests from the LAN succeeded after advertisement migration.

This establishes successful L2 ownership migration and post-failover service availability for the tested single-node outage.

## Recovery validation

After `k3s02` was powered back on:

- All three Kubernetes nodes returned to `Ready`.
- The MetalLB speaker on `k3s02` returned to `1/1 Running`.
- All three MetalLB speakers were healthy.
- The canary replica on `k3s02` restarted with a new pod address.
- The EndpointSlice again contained both canary replicas.
- Repeated LAN requests reached both replicas.
- MetalLB L2 ownership returned to `k3s02`.
- The MetalLB HelmRelease remained `Ready=True`.

This establishes successful node, speaker, workload-endpoint, and L2-announcement reintegration for the tested recovery.

## Evidence boundaries

This test does not establish:

- Zero-downtime failover
- A measured failover duration
- Absence of dropped requests during the transition
- Two-node or multi-node failure tolerance
- Persistent workload or storage recovery
- Production readiness

A continuous request monitor was not captured across the transition, so the result must not be described as zero-downtime failover.
