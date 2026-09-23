# Design: split Flux reconciliation with `dependsOn`

**Status:** Proposed. Not applied. No live manifests change until this plan is reviewed.

## Purpose

1. Split the single `flux-system` Kustomization into `infrastructure-controllers`, `infrastructure-configs`, and `apps`. Order them with `dependsOn` so that a MetalLB custom resource is never applied before its CRDs and webhook exist.
2. Restore Flux self-management of `clusters/home/flux-system`.
3. Transfer ownership of existing live objects without deleting or recreating them.

This does not introduce ingress, storage, secrets management, or cloud overlays.

## Current state

| Item | Observed in Git |
| --- | --- |
| Flux Kustomization | `flux-system/flux-system`, path `./clusters/home`, `prune: true` |
| Root `clusters/home/kustomization.yaml` | `resources: [infrastructure, apps]`. `flux-system` is **not** included |
| `clusters/home/infrastructure` | MetalLB `HelmRepository`, `HelmRelease`, and the `IPAddressPool`/`L2Advertisement` in **one** Kustomize unit |
| `clusters/home/apps` | `platform-canary` Namespace, Deployment, Service |

Expected contents of the `flux-system` inventory (to be confirmed in Phase 0):

| Inventory ID | Moves to |
| --- | --- |
| `flux-system_metallb_source.toolkit.fluxcd.io_HelmRepository` | `infrastructure-controllers` |
| `flux-system_metallb_helm.toolkit.fluxcd.io_HelmRelease` | `infrastructure-controllers` |
| `metallb-system_home-pool_metallb.io_IPAddressPool` | `infrastructure-configs` |
| `metallb-system_home-l2_metallb.io_L2Advertisement` | `infrastructure-configs` |
| `_platform-demo__Namespace` | `apps` |
| `platform-demo_platform-canary_apps_Deployment` | `apps` |
| `platform-demo_platform-canary__Service` | `apps` |

The `metallb-system` Namespace and all chart-rendered objects belong to the Helm release, not to a Flux Kustomization inventory.

### Problems

- **Clean-bootstrap ordering (suspected, not demonstrated).** On an empty cluster, the `IPAddressPool` and `L2Advertisement` are validated in the same apply as the `HelmRelease` that would install their CRDs. Flux's server-side dry-run is expected to reject the whole unit, so MetalLB would never install. The live cluster only works because these were introduced in separate commits. Static CI cannot confirm or rule this out.
- **Flux is not self-managed.** Changes to `gotk-components.yaml` or `gotk-sync.yaml` in Git have no effect on the cluster until `flux bootstrap` is run again.

## Why moving objects is dangerous

When a commit removes objects from the `flux-system` path and adds child Kustomizations that contain them, the following happens in order:

1. `flux-system` reconciles. It applies the new child Kustomization objects, and its new inventory no longer lists the moved objects.
2. **In the same reconcile**, `flux-system` garbage-collects objects that are missing from its new inventory. The children have not taken ownership yet.
3. Deleting the `HelmRelease` uninstalls MetalLB. Deleting the pool withdraws `10.0.0.220`. Deleting `platform-demo` removes the canary.
4. The children then recreate everything, with new UIDs and an outage.

The Flux documentation does not say that garbage collection checks ownership labels before deleting, so this plan does not rely on labels to prevent step 2. Deleting a Kustomization object also garbage-collects its inventory, which makes any rollback that deletes a child Kustomization equally dangerous.

## Safety mechanisms

| Mechanism | Documented behavior | Used for |
| --- | --- | --- |
| `kustomize.toolkit.fluxcd.io/prune: disabled` annotation | Objects carrying it are excluded from garbage collection | Protects every moving object from step 2 and from rollback deletion |
| `spec.deletionPolicy: Orphan` on child Kustomizations | Deleting the Kustomization leaves its managed objects in place | Second layer of protection if a child Kustomization is removed during rollback |
| Object UIDs recorded before and after | An unchanged UID shows the object was not deleted and recreated | Evidence of in-place ownership transfer |
| Continuous LAN request monitor | Timestamped success/failure samples | Evidence of availability during the change window |
| K3s etcd snapshot | Point-in-time cluster state | Last-resort recovery point |
| `flux suspend` / `spec.suspend: true` | Stops reconciliation | Emergency brake during any phase |

Each phase is a separate PR, merged only after the previous phase is validated live.

## Target layout

```text
clusters/home/
├── kustomization.yaml            # resources: flux-system, infrastructure.yaml, apps.yaml
├── flux-system/                  # generated; now reconciled by flux-system itself
├── infrastructure.yaml           # Flux Kustomizations: infrastructure-controllers, infrastructure-configs
├── apps.yaml                     # Flux Kustomization: apps
├── infrastructure/
│   ├── controllers/              # metallb.yaml (HelmRepository + HelmRelease)
│   └── configs/                  # metallb-pool.yaml (IPAddressPool + L2Advertisement)
└── apps/                         # unchanged
```

Home-specific content stays under `clusters/home`. Separating shared bases from per-environment overlays is left to the AKS/EKS work, so this migration moves as little as possible.

### Proposed Flux Kustomizations

```yaml
# clusters/home/infrastructure.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-controllers
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 10m
  path: ./clusters/home/infrastructure/controllers
  prune: true
  wait: true                  # Ready only once the HelmRelease is Ready (CRDs and webhook installed)
  deletionPolicy: Orphan      # migration only; removed in Phase 4
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure-controllers
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  path: ./clusters/home/infrastructure/configs
  prune: true
  wait: true
  deletionPolicy: Orphan      # migration only; removed in Phase 4
  sourceRef:
    kind: GitRepository
    name: flux-system
```

```yaml
# clusters/home/apps.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure-configs
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  path: ./clusters/home/apps
  prune: true
  wait: true
  deletionPolicy: Orphan      # migration only; removed in Phase 4
  sourceRef:
    kind: GitRepository
    name: flux-system
```

## Migration phases

All cluster commands run on a K3s node with `sudo kubectl`. Where it helps, the node needs a read-only clone of this public repository (`git clone https://github.com/triley76/home-cluster`).

### Phase 0: Pre-flight evidence (read-only, no PR)

1. Confirm that Flux and the objects are healthy:

   ```bash
   sudo kubectl get kustomizations.kustomize.toolkit.fluxcd.io,gitrepositories.source.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A
   ```

2. Record the `flux-system` inventory, and compare it with the table above:

   ```bash
   sudo kubectl -n flux-system get kustomization flux-system \
     -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'
   ```

   If any `flux-system/*` component objects, such as Flux Deployments or CRDs, already appear, stop and revise Phase 1.

3. Record the UID, owner label, and prune annotation of every moving object:

   ```bash
   for r in \
     "flux-system helmrepository.source.toolkit.fluxcd.io/metallb" \
     "flux-system helmrelease.helm.toolkit.fluxcd.io/metallb" \
     "metallb-system ipaddresspool.metallb.io/home-pool" \
     "metallb-system l2advertisement.metallb.io/home-l2" \
     "platform-demo deployment.apps/platform-canary" \
     "platform-demo service/platform-canary"; do
     set -- $r
     printf '%-55s ' "$2"
     sudo kubectl -n "$1" get "$2" -o jsonpath='{.metadata.uid}{"  "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"  "}{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
   done
   printf '%-55s ' namespace/platform-demo
   sudo kubectl get namespace platform-demo -o jsonpath='{.metadata.uid}{"  "}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'
   ```

4. Record the Helm release revision, service address, pods, and L2 owner:

   ```bash
   sudo kubectl -n flux-system get helmrelease metallb -o jsonpath='{.status.history[0].version}{"\n"}'
   sudo kubectl -n platform-demo get svc platform-canary -o wide
   sudo kubectl -n platform-demo get pods -o wide
   sudo kubectl -n metallb-system get pods -o wide
   sudo kubectl -n metallb-system get servicel2statuses -o wide
   ```

5. Confirm the assumptions this plan relies on:
   - `sudo kubectl explain kustomizations.spec.deletionPolicy --api-version=kustomize.toolkit.fluxcd.io/v1` lists `Orphan`.
   - The Flux controller images in `gotk-components.yaml` match the running images (`sudo kubectl -n flux-system get deploy -o wide`).
   - The field manager used by kustomize-controller, found by running `sudo kubectl -n platform-demo get deploy platform-canary --show-managed-fields -o yaml | grep 'manager:'`.

6. Take a recovery point: `sudo k3s etcd-snapshot save --name pre-flux-split`.

### Phase 1: Restore `flux-system` self-management

**Change:**
- Add `flux-system` to `clusters/home/kustomization.yaml`.
- Add a CI assertion that the root kustomization still lists `flux-system` (see "Hazard" below).

**Why first:** this change only adds objects to the inventory. It removes nothing, so no garbage collection happens. Once it is live, the `flux-system` Kustomization spec in `gotk-sync.yaml` becomes the source of truth.

**Before merging:** preview what kustomize-controller would change on the controllers:

```bash
sudo kubectl kustomize clusters/home/flux-system \
  | sudo kubectl diff --server-side --force-conflicts --field-manager=<manager from Phase 0> -f -
```

The expected result is no changes, or only metadata such as labels and managed fields. Any change to a controller Deployment spec (images, arguments, resources) blocks the merge. Regenerate `gotk-components.yaml` with the matching `flux` CLI version and flags first.

**Validate after merging:**
- `flux-system` shows `Ready=True` at the merge revision.
- The inventory now contains the Flux component objects, and the moving objects are still listed.
- The Flux controller pods were not restarted, or any restart has an explanation from the diff.
- The canary is still reachable at `10.0.0.220`.

**Hazard:** once Flux manages itself, removing `flux-system` from the root kustomization garbage-collects Flux's own CRDs and controllers, which deletes every Flux custom resource. The CI assertion guards against that edit.

**Rollback:** fix forward, for example by regenerating the components. If un-managing is truly needed, do it in three steps:
1. Set `prune: false` in `gotk-sync.yaml` and let it reconcile.
2. Remove `flux-system` from the root.
3. Restore `prune: true` with `kubectl patch`.

Never make the removal in a single revert.

### Phase 2: Protect moving objects from pruning

**Change:** add `kustomize.toolkit.fluxcd.io/prune: disabled` to `metadata.annotations` of all seven moving objects, editing each file directly.

- Do not use Kustomize `commonAnnotations`. It also annotates the Deployment's pod template, which would roll the canary pods.
- A metadata-only annotation does not change the Deployment's pod template, the `HelmRelease` generation, or the Service's MetalLB allocation.

**Validate after merging:**
- Every moving object shows the annotation (the Phase 0 loop).
- Every UID is unchanged.
- The Helm release revision is unchanged.
- The canary pods were not restarted.

**Rollback:** revert the PR. Removing an annotation deletes nothing.

### Phase 3: Split reconciliation (the ownership transfer)

**Change, in one commit:**
- `git mv clusters/home/infrastructure/metallb.yaml clusters/home/infrastructure/controllers/`
- `git mv clusters/home/infrastructure/metallb-pool.yaml clusters/home/infrastructure/configs/`
- Add `kustomization.yaml` in `controllers/` and `configs/`, and remove `clusters/home/infrastructure/kustomization.yaml`.
- Add `clusters/home/infrastructure.yaml` and `clusters/home/apps.yaml`, as proposed above.
- Set the root resources to `flux-system`, `infrastructure.yaml`, and `apps.yaml`.
- Keep the Phase 2 annotations in the moved files.

**During the change window:** run the LAN monitor on the Windows workstation from before the merge until validation is complete:

```powershell
$log = "canary-monitor-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
while ($true) {
  $t = Get-Date -Format o
  try {
    $r = Invoke-WebRequest http://10.0.0.220/ -UseBasicParsing -TimeoutSec 2
    $h = ($r.Content -split "`n" | Where-Object { $_ -like 'Hostname:*' })
    "$t,ok,$h" | Add-Content $log
  } catch {
    "$t,fail,$($_.Exception.Message)" | Add-Content $log
  }
  Start-Sleep -Milliseconds 500
}
```

**Expected sequence:**
1. `flux-system` applies the three child Kustomizations.
2. The moved objects leave its inventory, and garbage collection skips them because of the annotation.
3. `infrastructure-controllers` applies and becomes Ready once the `HelmRelease` is Ready.
4. `infrastructure-configs` then applies.
5. `apps` then applies.
6. Each child takes over its objects in place.

**Validate after merging:**
- All four Kustomizations show `Ready=True` at the merge revision.
- Each child's inventory contains exactly its expected IDs.
- The `flux-system` inventory contains only the Flux components and the three child Kustomizations.
- Every UID is unchanged, and the `kustomize.toolkit.fluxcd.io/name` label now names the new owner.
- The Helm release revision is unchanged, so no upgrade or reinstall happened.
- The MetalLB and canary pods were not restarted, the service is still at `10.0.0.220`, and the L2 owner is unchanged or its change is explained.
- The monitor log shows no `fail` rows. If there are any, record them as they are.

**Rollback while the annotations and `Orphan` are still in place:** revert the PR. `flux-system` takes the objects back. Deleting the child Kustomizations orphans their objects, and the annotation stops garbage collection from removing them. Confirm the UIDs afterwards.

### Phase 4: Return to normal garbage collection

**Change:**
- Remove the Phase 2 annotations.
- Remove `deletionPolicy: Orphan` from the child Kustomizations, so the default `MirrorPrune` applies.

**Validate after merging:**
- The annotations are gone from the live objects. The same field manager owns the field, so server-side apply should remove it.
- The UIDs are unchanged.
- All Kustomizations are Ready.

**Consequence:** from here on, deleting a child Kustomization or removing an object from its path deletes the live object. This is normal Flux behavior. Future moves between Kustomizations should reuse the Phase 2–4 pattern.

### Phase 5: Documentation

Record the observed evidence in `docs/validation/`. Update the README structure and the handover only for what was demonstrated.

## Evidence boundaries

If Phases 0–4 pass, they show that:
- ownership moved in place without recreating any object;
- Flux manages itself again;
- the ordered Kustomizations reconcile on the existing cluster;
- LAN availability held at the monitor's sample rate during this change window.

They do **not** show that a clean bootstrap succeeds. That needs a separate test on a disposable cluster: a fresh `flux bootstrap` followed by the ordered reconcile. Note that the `ens160` interface selector in the L2Advertisement would not match on a k3d/kind cluster, so such a test would prove ordering and readiness, not LAN advertisement.

Static CI can confirm that the new Flux Kustomization objects are valid against their schemas. It cannot confirm the ordering behavior.

## Open decisions for review

1. Should the migration-only `deletionPolicy: Orphan` stay permanently on `infrastructure-*`, to guard MetalLB against accidental Kustomization deletion? The cost is that intentional removal becomes a manual cleanup.
2. Should the `wait: true` health checks be replaced with explicit `healthChecks`, which would be narrower?
3. How should the clean-bootstrap test run: a disposable VM from `homelab-k3s`, or k3d in CI?
