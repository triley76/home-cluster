# Flux reconciliation-split validation

## Scope

This record documents the observed results of Phases 3 and 4 of the [Flux reconciliation-split design](../design/flux-reconciliation-split.md) on the three-node V2 K3s cluster, and the k3d tests that gated Phase 3.

- **Phase 3** split reconciliation into `infrastructure-controllers` → `infrastructure-configs` → `apps` and transferred ownership of seven live objects from the root `flux-system` Kustomization to those child Kustomizations.
- **Phase 4** removed the temporary migration protections and restored normal Flux garbage-collection semantics.

Phase 0 results are recorded in the design document under [Phase 0 observed evidence](../design/flux-reconciliation-split.md#phase-0-observed-evidence).

Evidence files referred to below are stored outside this repository. The Phase 3 live evidence is on `k3s01` under `/home/ansible/flux-split`.

## Objects transferred

| Object | Owner before Phase 3 | Owner after Phase 3 |
| --- | --- | --- |
| HelmRepository `flux-system/metallb` | `flux-system` | `infrastructure-controllers` |
| HelmRelease `flux-system/metallb` | `flux-system` | `infrastructure-controllers` |
| IPAddressPool `metallb-system/home-pool` | `flux-system` | `infrastructure-configs` |
| L2Advertisement `metallb-system/home-l2` | `flux-system` | `infrastructure-configs` |
| Namespace `platform-demo` | `flux-system` | `apps` |
| Deployment `platform-demo/platform-canary` | `flux-system` | `apps` |
| Service `platform-demo/platform-canary` | `flux-system` | `apps` |

## Pre-merge k3d gates for Phase 3

Two tests ran on disposable k3d clusters before the Phase 3 merge, and both passed:

| Test | What it exercised |
| --- | --- |
| Ownership-transfer rehearsal | The Phase 2 → Phase 3 transition with the real root `flux-system` Kustomization reconciling `./clusters/home` (self-management included, `gotk-sync.yaml` unmodified), served by an in-cluster Git mirror |
| Clean bootstrap | The Phase 3 tree reconciled from an empty cluster, with the controllers layer installing the MetalLB CRDs before the configs layer applied the IPAddressPool and L2Advertisement |

Evidence boundaries of the k3d tests:

- k3d does not reproduce MetalLB L2 advertisement, ARP, `ens160`, kube-vip, or LAN reachability. Availability in k3d was measured through the Service ClusterIP only.
- k3d runs a single node; the live cluster has three.
- The rehearsal reached its Phase 2 starting state through a staged, k3d-only bootstrap, so object history and field managers differed from the live cluster.
- A passing k3d test does not establish a clean bootstrap of the VMware/K3s cluster.

## Phase 3: live ownership transfer

Merged as `main@sha1:7f373e2deff6a8666492b1a90475324afd38d174`.

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All four (`flux-system`, `infrastructure-controllers`, `infrastructure-configs`, `apps`) became `Ready=True` at the merge revision |
| Object UIDs | All seven transferred objects kept their original UIDs, so none was deleted or recreated |
| Ownership | Moved to the intended child Kustomizations, as listed in [Objects transferred](#objects-transferred) |
| MetalLB Helm revision | Remained 2 |
| Pods | Pod UIDs and restart counts were unchanged during the migration |
| Service address | LoadBalancer IP remained `10.0.0.220` |
| L2 announcement | The announcing node remained `k3s02` |
| Stability | The snapshot taken immediately after the migration and the snapshot taken more than one hour later were identical |
| LAN monitor | 1,293 requests from the Windows LAN monitor, with zero failures and both replicas responding |

MetalLB regenerated its `ServiceL2Status` object during reconciliation. The speaker pod UID, the announcing node, and the service address were unchanged.

**No interruption was observed during the Phase 3 migration window**, at the monitor's sample rate.

## Phase 4: return to normal garbage collection

Merged as `main@sha1:d716e526a929c406e06214950aefe0def3d2e203`.

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All four became `Ready=True` at the merge revision |
| Prune protection | The seven `kustomize.toolkit.fluxcd.io/prune: disabled` annotations were removed from the live objects |
| Deletion policy | The three temporary `deletionPolicy: Orphan` fields were removed from the child Kustomizations |
| Object UIDs | All seven were unchanged |
| Ownership labels and inventories | Unchanged; every object stayed in its Phase 3 child Kustomization |
| MetalLB Helm revision | Remained 2 |
| Service address | LoadBalancer IP remained `10.0.0.220` |
| L2 announcement | L2 ownership remained on `k3s02` |

Phase 4 restored normal Flux garbage-collection semantics. From this point on:

- removing an object from a child Kustomization's path deletes the live object;
- deleting a child Kustomization deletes its managed objects.

### Later host reboot (not part of Phase 4)

After Phase 4 reconciled, the owner reported a reboot of the Windows/VMware host environment. These changes are attributed to that reboot, not to Phase 4:

- The restart count of every monitored container increased by two. Pod UIDs were unchanged.
- MetalLB regenerated the ephemeral `ServiceL2Status` object under a new name.

### Phase 4 LAN monitoring

Two monitor files cover Phase 4. Both are stored outside this repository.

| Monitor | File | SHA-256 |
| --- | --- | --- |
| Original overnight monitor | `phase4-lan-monitor-20260928T203259.tsv` | `0A73CA4DF91E935560B2DC82E70629DB44888C9E82EAA40A78890DEBA9F12817` |
| Post-reboot one-hour stability monitor | `phase4-final-stability-20260930T111815.tsv` | `41BFB7D51ABD12A356DB1DAF7C3D81C0255A6DAE3F38695789B13A69614F7613` |

**Original overnight monitor (`phase4-lan-monitor-20260928T203259.tsv`).** It did **not** run failure-free and was not continuous across the reboot:

| Measure | Value |
| --- | --- |
| Parsed requests | 84,656 |
| Successes | 84,641 |
| Failures | 15 |
| Failures during the Windows/VMware reboot | 13 |
| Other failures | 2 isolated timeouts of about two seconds each |

The file contains embedded NUL characters, caused by mixed PowerShell output encoding. It was analyzed through an in-memory normalization that removed the NUL characters without modifying the evidence file. The counts above come from that normalized analysis, and the SHA-256 above is that of the unmodified file.

**After the environment recovered:**

- a 40-request check passed with zero failures, and both replicas responded;
- the post-reboot one-hour stability monitor (`phase4-final-stability-20260930T111815.tsv`) recorded 4,825 successful requests with zero failures, and both replicas responded.

## Evidence boundaries

This evidence establishes that:

- ownership of the seven objects moved from the root `flux-system` Kustomization to the intended child Kustomizations without any object being deleted or recreated, and without a Helm upgrade;
- the layered Kustomizations reconcile on the live cluster, and the root `flux-system` Kustomization, whose path includes `clusters/home/flux-system`, was `Ready=True` at both merge revisions;
- no interruption was observed during the Phase 3 migration window, at the monitor's sample rate;
- Phase 4 removed the temporary protections without changing object identity, ownership, or the service address.

It does **not** establish:

- zero-downtime behavior in general, or outside the monitored windows;
- that the two isolated Phase 4 timeouts had any particular cause;
- a clean bootstrap of the real VMware/K3s cluster, including kube-vip and MetalLB L2;
- two-node or multi-node failure tolerance;
- production readiness.
