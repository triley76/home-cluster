# Design: split Flux reconciliation with `dependsOn`

**Status:** Proposed. Not applied. No live manifests change until this design is reviewed and approved. Each migration phase below is a separate PR.

## Purpose

1. Split the single `flux-system` Kustomization into `infrastructure-controllers`, `infrastructure-configs`, and `apps`. Order them with `dependsOn` so that MetalLB custom resources are never applied before MetalLB's CRDs and webhook exist.
2. Restore Flux self-management of `clusters/home/flux-system`.
3. Transfer ownership of existing live objects without deleting or recreating them.

This does not introduce ingress, storage, secrets management, or cloud overlays.

## Decisions

| Topic | Decision |
| --- | --- |
| `deletionPolicy: Orphan` | Temporary, during the ownership migration only. It is removed in Phase 4, after UIDs, Helm revision, ownership labels, Flux readiness, and service availability have been validated. |
| Health checking | Start with `wait: true` on each child Kustomization. Each layer is small, so `wait` covers a known, short list of resources. See [Readiness and timeouts](#readiness-and-timeouts). |
| Clean-bootstrap test | Run the first test in k3d, to validate GitOps dependency and CRD ordering only. Validation of kube-vip, `ens160`, ARP, and MetalLB L2 on VMware/K3s is a separate, later test. |
| Delivery | Every migration phase is a separate PR, merged only after the previous phase is validated live. Implementation starts only after this design PR is approved. |
| Safety | Every phase has explicit stop conditions and rollback commands, listed below. |

## Current state

| Item | Observed in Git |
| --- | --- |
| Flux Kustomization | `flux-system/flux-system`, path `./clusters/home`, `prune: true` |
| Root `clusters/home/kustomization.yaml` | `resources: [infrastructure, apps]`. `flux-system` is **not** included |
| `clusters/home/infrastructure` | MetalLB `HelmRepository`, `HelmRelease`, and the `IPAddressPool`/`L2Advertisement` in **one** Kustomize unit |
| `clusters/home/apps` | `platform-canary` Namespace, Deployment, Service |

Expected `flux-system` inventory, to be confirmed in Phase 0:

| Inventory ID | Moves to |
| --- | --- |
| `flux-system_metallb_source.toolkit.fluxcd.io_HelmRepository` | `infrastructure-controllers` |
| `flux-system_metallb_helm.toolkit.fluxcd.io_HelmRelease` | `infrastructure-controllers` |
| `metallb-system_home-pool_metallb.io_IPAddressPool` | `infrastructure-configs` |
| `metallb-system_home-l2_metallb.io_L2Advertisement` | `infrastructure-configs` |
| `_platform-demo__Namespace` | `apps` |
| `platform-demo_platform-canary_apps_Deployment` | `apps` |
| `platform-demo_platform-canary__Service` | `apps` |

The `metallb-system` Namespace and everything the chart renders belong to the Helm release, not to a Flux Kustomization inventory.

### Problems

- **Clean-bootstrap ordering (suspected, not demonstrated).** On an empty cluster, the `IPAddressPool` and `L2Advertisement` are validated in the same apply as the `HelmRelease` that installs their CRDs. Flux's server-side dry-run is expected to reject the whole unit, so MetalLB would never install. The live cluster works only because these objects were added in separate commits. Static CI cannot confirm or rule this out. The k3d test's negative control is designed to confirm it.
- **Flux is not self-managed.** Changes to `gotk-components.yaml` or `gotk-sync.yaml` have no effect on the cluster until `flux bootstrap` is run again.

## Why moving objects is dangerous

When one commit removes objects from the `flux-system` path and adds child Kustomizations that contain them:

1. `flux-system` reconciles. It applies the new child Kustomization objects, and its new inventory no longer lists the moved objects.
2. **In the same reconcile**, `flux-system` garbage-collects the missing objects. The children have not taken ownership yet.
3. Deleting the `HelmRelease` uninstalls MetalLB. Deleting the pool withdraws `10.0.0.220`. Deleting `platform-demo` removes the canary.
4. The children then recreate everything, with new UIDs and after an outage.

The Flux documentation does not say that garbage collection checks ownership labels before deleting, so this plan does not rely on labels. Deleting a Kustomization object also garbage-collects its whole inventory. That makes any rollback that deletes a child Kustomization equally dangerous unless the objects are protected.

## Safety mechanisms

| Mechanism | Documented behavior | Used for |
| --- | --- | --- |
| `kustomize.toolkit.fluxcd.io/prune: disabled` annotation | Flux skips the object during garbage collection | Protecting moving objects from step 2 and from rollback deletion |
| `spec.deletionPolicy: Orphan` | Deleting the Kustomization leaves its managed objects in place | A second layer of protection if a child Kustomization is deleted during rollback |
| Before/after snapshots | An unchanged UID shows the object was not deleted and recreated | Evidence of in-place ownership transfer, and the basis for most stop conditions |
| Continuous LAN request monitor | Timestamped success/failure samples | Evidence of availability during a change window |
| K3s etcd snapshot | Point-in-time cluster state | Last-resort recovery point |
| `spec.suspend: true` | Stops reconciliation of that Kustomization | Emergency brake |

## Target layout

```text
clusters/home/
├── kustomization.yaml            # resources: flux-system, infrastructure.yaml, apps.yaml
├── flux-system/                  # generated; reconciled by flux-system itself
├── infrastructure.yaml           # Flux Kustomizations: infrastructure-controllers, infrastructure-configs
├── apps.yaml                     # Flux Kustomization: apps
├── infrastructure/
│   ├── controllers/              # metallb.yaml (HelmRepository + HelmRelease)
│   └── configs/                  # metallb-pool.yaml (IPAddressPool + L2Advertisement)
└── apps/                         # unchanged
```

Home-specific content stays under `clusters/home`, so this migration moves as little as possible. Separating shared bases from per-environment overlays belongs to the AKS/EKS work.

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
  wait: true
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

## Readiness and timeouts

With `wait: true`, a Kustomization becomes `Ready=True` only after every object it applied reaches kstatus `Current`. `dependsOn` then holds each dependent back until the layer before it is `Ready=True`.

| Layer | Waits for | What `Current` means | What it does **not** show |
| --- | --- | --- | --- |
| `infrastructure-controllers` (timeout 10m) | `HelmRepository/metallb`, `HelmRelease/metallb` | The chart index was fetched, and the Helm install or upgrade succeeded. helm-controller waits for the chart's workloads by default, which covers the MetalLB controller, the speaker DaemonSet, and the CRDs and webhook the chart installs. | That L2 announcements work |
| `infrastructure-configs` (timeout 5m) | `IPAddressPool/home-pool`, `L2Advertisement/home-l2` | The API server accepted the objects, including the MetalLB validating webhook. These kinds have no status conditions, so kstatus treats them as `Current` once they exist. | That MetalLB has allocated or announced anything |
| `apps` (timeout 5m) | `Namespace/platform-demo`, `Deployment/platform-canary`, `Service/platform-canary` | The Namespace is `Active` and the Deployment rollout is complete, with all replicas available. For a `LoadBalancer` Service, kstatus is expected to report `InProgress` until `status.loadBalancer.ingress` is set. This is to be confirmed in the k3d test. | Reachability from the LAN |

**Timeout behavior:**

- `timeout` bounds the apply and the health check for one reconcile attempt.
- On expiry, the Kustomization reports `Ready=False` (health check failed) and retries after `retryInterval` (1m).
- Dependents report that a dependency is not ready and do not apply. They retry on their own `retryInterval`.
- A timeout never deletes or rolls back anything that was already applied. Live objects keep running as they are.
- The `HelmRelease` has its own timeout (Helm default 5m) and install/upgrade remediation (3 retries). A failing Helm operation can therefore outlast one Kustomization attempt; the Kustomization then keeps retrying until the release is Ready or someone intervenes.

## Common procedures

These are referenced by every phase. Run cluster commands on a K3s node with `sudo kubectl`.

### Snapshot (S)

Save this as `~/flux-split/snapshot.sh` on the node. Run it as `snapshot.sh > ~/flux-split/<phase>-<before|after>.txt`, then compare two snapshots with `diff`.

```bash
#!/usr/bin/env bash
set -uo pipefail
k() { sudo kubectl "$@"; }
FIELDS='{.metadata.uid}{"\t"}{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\t"}{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
echo "## objects: uid  owner  prune-annotation"
for r in \
  "flux-system helmrepository.source.toolkit.fluxcd.io/metallb" \
  "flux-system helmrelease.helm.toolkit.fluxcd.io/metallb" \
  "metallb-system ipaddresspool.metallb.io/home-pool" \
  "metallb-system l2advertisement.metallb.io/home-l2" \
  "platform-demo deployment.apps/platform-canary" \
  "platform-demo service/platform-canary"; do
  set -- $r; printf '%s\t' "$2"; k -n "$1" get "$2" -o jsonpath="$FIELDS"
done
printf 'namespace/platform-demo\t'; k get namespace platform-demo -o jsonpath="$FIELDS"
echo "## helm release revision"
k -n flux-system get helmrelease metallb -o jsonpath='{.status.history[0].version}{"\n"}'
echo "## kustomizations"
k -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[?\(@.type==\"Ready\"\)].status,REV:.status.lastAppliedRevision,SUSPEND:.spec.suspend,DELETION:.spec.deletionPolicy
echo "## inventories"
for ks in $(k -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io -o name); do
  echo "# $ks"; k -n flux-system get "$ks" -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}' | sort
done
echo "## pods: uid  restarts  node"
for ns in flux-system metallb-system platform-demo; do
  k -n "$ns" get pods -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName --no-headers | sort
done
echo "## service and L2 owner"
k -n platform-demo get svc platform-canary -o jsonpath='{.status.loadBalancer.ingress[*].ip}{"\n"}'
k -n metallb-system get servicel2statuses -o custom-columns=NAME:.metadata.name,NODE:.status.node --no-headers 2>/dev/null
```

### LAN monitor (M)

Run this on the Windows workstation, from before the merge until validation is complete. Afterwards, count the failures with `(Select-String ',fail,' $log).Count`.

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

### Emergency brake (E)

Suspend reconciliation without changing Git. A suspend set with `kubectl` belongs to a different field manager than Flux, and a suspended Kustomization does not reconcile, so the suspend holds until it is removed.

```bash
# Suspend (all, or name specific Kustomizations)
for ks in flux-system infrastructure-controllers infrastructure-configs apps; do
  sudo kubectl -n flux-system patch kustomizations.kustomize.toolkit.fluxcd.io "$ks" \
    --type merge -p '{"spec":{"suspend":true}}' 2>/dev/null
done
# Resume later, one at a time, starting with flux-system
sudo kubectl -n flux-system patch kustomizations.kustomize.toolkit.fluxcd.io flux-system \
  --type merge -p '{"spec":{"suspend":false}}'
```

### Revert and force reconcile (R)

Run on the workstation:

```bash
git switch main && git pull --ff-only
git switch -c revert/<phase>
git revert -m 1 <merge-commit-sha>
git push -u origin revert/<phase>   # open and merge the revert PR
```

Then, on a node, fetch and reconcile immediately instead of waiting for the interval:

```bash
now=$(date +%s)
sudo kubectl -n flux-system annotate --overwrite gitrepositories.source.toolkit.fluxcd.io flux-system reconcile.fluxcd.io/requestedAt="$now"
sudo kubectl -n flux-system annotate --overwrite kustomizations.kustomize.toolkit.fluxcd.io flux-system reconcile.fluxcd.io/requestedAt="$now"
```

## Migration phases

### Phase 0: Pre-flight evidence (read-only, no PR)

**Steps:**

1. Save and run snapshot S as `phase0.txt`.
2. Confirm the assumptions this plan relies on:
   - `sudo kubectl explain kustomizations.spec.deletionPolicy --api-version=kustomize.toolkit.fluxcd.io/v1` lists `Orphan`.
   - The Flux controller images in `clusters/home/flux-system/gotk-components.yaml` match `sudo kubectl -n flux-system get deploy -o wide`.
   - Find the kustomize-controller field manager with `sudo kubectl -n platform-demo get deploy platform-canary --show-managed-fields -o yaml | grep 'manager:'`.
3. Take a recovery point with `sudo k3s etcd-snapshot save --name pre-flux-split`, and check it with `sudo k3s etcd-snapshot ls`.
4. Run the k3d clean-bootstrap negative control, described [below](#k3d-clean-bootstrap-test).

**Stop and do not start Phase 1 if any of these is true:**

- A Kustomization or HelmRelease is not `Ready=True`, or the canary is not reachable at `10.0.0.220`.
- The `flux-system` inventory differs from the expected table, for example because Flux component objects are already listed.
- `deletionPolicy` does not offer `Orphan`.
- The Flux images differ between Git and the cluster.
- The etcd snapshot fails.

**Rollback:** none needed. This phase changes nothing.

### Phase 1: Restore `flux-system` self-management (PR 1)

**Change:**

- Add `flux-system` to `clusters/home/kustomization.yaml`.
- Add a CI assertion that the root kustomization still lists `flux-system`.

This change only adds objects to the inventory, so nothing is garbage-collected. Once it is live, `gotk-sync.yaml` becomes the source of truth for the `flux-system` Kustomization.

**Before merging:** run snapshot S as `phase1-before.txt`, and preview the controller changes from a clone of the PR branch:

```bash
sudo kubectl kustomize clusters/home/flux-system \
  | sudo kubectl diff --server-side --force-conflicts --field-manager=<manager from Phase 0> -f -
```

**Stop before merging if:**

- The diff changes any Deployment `spec`: images, arguments, resources, or the pod template.
- The diff changes a CRD schema.
- The diff changes the `flux-system` GitRepository or Kustomization spec: URL, branch, path, prune, or intervals.

Labels and managed fields alone are acceptable. Fix spec differences by regenerating `gotk-components.yaml` with the matching `flux` CLI version and flags, then run the diff again.

**Validate after merging:** within 10 minutes, run snapshot S as `phase1-after.txt` and compare it with `phase1-before.txt`. Expect:

- `flux-system` shows `Ready=True` at the merge revision.
- Its inventory gained the Flux component objects and still lists the 7 moving objects.
- Every object UID and pod UID is unchanged.

**Stop conditions after merging:**

| Observation | Action |
| --- | --- |
| `flux-system` not Ready after 10 minutes, or Flux controller pods crash-looping | Apply E to `flux-system`. Re-apply the known-good controllers: `git show <pre-merge-sha>:clusters/home/flux-system/gotk-components.yaml \| sudo kubectl apply --server-side --force-conflicts -f -`. Investigate before resuming. |
| Any moving object is missing from the inventory, or any object UID changed | Apply E, then investigate. Do not continue to Phase 2. |
| Flux controller pods restarted, and the pre-merge diff doesn't explain it | Record it and investigate before Phase 2. |

**Rollback: never a plain revert.** Removing `flux-system` from the root while it is self-managed garbage-collects Flux's own CRDs and controllers. Fix forward if at all possible. If Flux must stop managing itself, use three separate PRs:

1. **PR 1a:** set `prune: false` in `gotk-sync.yaml`. After it reconciles, confirm that `sudo kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io flux-system -o jsonpath='{.spec.prune}'` prints `false`.
2. **PR 1b:** remove `flux-system` from the root, and restore `gotk-sync.yaml` to its generated content with `prune: true`. The file is no longer applied at that point. After it reconciles, confirm that the Flux pods and CRDs still exist and that the inventory no longer lists them.
3. **Live patch:** run `sudo kubectl -n flux-system patch kustomizations.kustomize.toolkit.fluxcd.io flux-system --type merge -p '{"spec":{"prune":true}}'`.

### Phase 2: Protect moving objects from pruning (PR 2)

**Change:** add `kustomize.toolkit.fluxcd.io/prune: disabled` under `metadata.annotations` of all 7 moving objects, editing each file directly.

- Do not use Kustomize `commonAnnotations`. It would also annotate the Deployment pod template and restart the canary pods.
- A metadata-only annotation does not change the Deployment pod template, the `HelmRelease` generation, or the Service's MetalLB allocation.

**Before merging:** run snapshot S as `phase2-before.txt`.

**Validate after merging:** run snapshot S as `phase2-after.txt` and compare. Expect:

- All 7 objects show `disabled` in the prune column.
- Every object UID and pod UID is unchanged.
- The Helm revision is unchanged.
- All Kustomizations are Ready.

**Stop conditions after merging:**

| Observation | Action |
| --- | --- |
| Any object is missing the annotation | Do not start Phase 3. Fix it in a follow-up PR and validate again. |
| The Helm revision increased, a pod UID changed, or an object UID changed | Revert with R, then investigate. The design assumed metadata-only changes. |

**Rollback:** revert with R. Removing an annotation deletes nothing. Afterwards, confirm with snapshot S that the UIDs are unchanged and the annotations are gone.

### Phase 3: Split reconciliation, the ownership transfer (PR 3)

**Change, in one commit:**

- `git mv clusters/home/infrastructure/metallb.yaml clusters/home/infrastructure/controllers/`
- `git mv clusters/home/infrastructure/metallb-pool.yaml clusters/home/infrastructure/configs/`
- Add a `kustomization.yaml` to `controllers/` and to `configs/`, and remove `clusters/home/infrastructure/kustomization.yaml`.
- Add `clusters/home/infrastructure.yaml` and `clusters/home/apps.yaml`, as proposed above.
- Set the root resources to `flux-system`, `infrastructure.yaml`, and `apps.yaml`.
- Keep the Phase 2 annotations in the moved files.

**Before merging:**

1. Run the k3d positive test against the pushed PR 3 branch. It must pass.
2. Run snapshot S as `phase3-before.txt`, and confirm from it:
   - all 7 objects show `prune: disabled`;
   - all Kustomizations are Ready;
   - no Kustomization is suspended.
3. Start monitor M, and confirm it has logged at least one minute of `ok` rows.

**Stop before merging if:** any item above fails. Most importantly, do not merge unless every moving object carries the annotation live.

**Expected sequence:**

1. `flux-system` applies the three child Kustomizations.
2. The moved objects leave its inventory, and garbage collection skips them because of the annotation.
3. `infrastructure-controllers` becomes Ready once `HelmRelease/metallb` is Ready.
4. `infrastructure-configs` applies and becomes Ready.
5. `apps` applies and becomes Ready.
6. Each child takes over its objects in place.

**Validate after merging:** run snapshot S as `phase3-after.txt` and compare. Expect:

- All four Kustomizations show `Ready=True` at the merge revision.
- Each child's inventory contains exactly its expected IDs.
- The `flux-system` inventory contains only the Flux components and the three child Kustomizations.
- Every object UID is unchanged, and the owner column names the new child Kustomization.
- The Helm revision is unchanged, and the MetalLB and canary pod UIDs are unchanged.
- The service is still at `10.0.0.220`, and the L2 owner is unchanged or its change is explained.
- Monitor M logged zero `fail` rows. If there are any, record them as they are.

**Stop conditions after merging:**

| Observation | Action |
| --- | --- |
| Any object UID changed (it was deleted and recreated) | Apply E to all Kustomizations and preserve the logs (`sudo kubectl -n flux-system logs deploy/kustomize-controller`). Protection failed, so a revert cannot undo that recreation. Restore service first, then investigate before any other change. |
| A child Kustomization is not Ready after 15 minutes | Nothing has been lost; objects that were already applied keep running. Inspect with `sudo kubectl -n flux-system describe kustomizations.kustomize.toolkit.fluxcd.io <name>`. If the cause isn't a quick fix, revert with R. |
| Helm revision increased | Apply E to `infrastructure-controllers`, inspect `sudo kubectl -n flux-system describe helmrelease metallb`, and revert with R if the release is unhealthy. |
| Monitor shows continuous failures for more than 30 seconds | Revert with R immediately, and investigate from the snapshots. |
| Inventory or ownership doesn't match expectations, while UIDs are unchanged | Do not start Phase 4. Investigate, then fix forward or revert with R. |

**Rollback while the annotations and `Orphan` are still present:** revert with R. What should happen:

1. `flux-system` applies the moved objects again and takes back their labels.
2. It then garbage-collects the three child Kustomization objects.
3. Their `Orphan` policy, and the annotation on each object, keep the managed objects in place.

Confirm with snapshot S that:

- only `flux-system` remains;
- every UID is unchanged;
- the owner column shows `flux-system` again.

### Phase 4: Return to normal garbage collection (PR 4)

**Change:**

- Remove the Phase 2 annotations.
- Remove `deletionPolicy: Orphan` from the three child Kustomizations, so the default `MirrorPrune` applies.

**Before merging:** all of the following must be established from the `phase3-after.txt` snapshot, a new snapshot, and the monitor log:

- The UIDs of all 7 moving objects are unchanged since Phase 0.
- The Helm revision is unchanged since Phase 0.
- The owner labels name the correct child for every object.
- All four Kustomizations are `Ready=True`, and have stayed Ready through at least one scheduled reconcile of every child (1 hour).
- The service is reachable at `10.0.0.220`, the monitor log shows zero `fail` rows or the failures are explained, and both replicas answer.

**Stop before merging if:** any item above is missing or unexplained. Stay in the Phase 3 state, which is safe and protected, until it is resolved.

**Validate after merging:** run snapshot S as `phase4-after.txt`. Expect:

- The prune column is empty for every object.
- The `DELETION` column is empty or shows the default for every child.
- Every UID is unchanged, and every Kustomization is Ready.

**Stop conditions after merging:**

| Observation | Action |
| --- | --- |
| An annotation is still present on a live object (another field manager owns it) | Record it. Remove the field with `sudo kubectl annotate <object> kustomize.toolkit.fluxcd.io/prune-` only after confirming which manager owns it, then run snapshot S again. |
| Any UID changed | Apply E to all Kustomizations and investigate. This is not expected from removing an annotation. |

**Rollback:** revert with R. This restores the annotations and `Orphan`, and deletes nothing.

**Consequence:** from here on, deleting a child Kustomization, or removing an object from its path, deletes the live object. This is normal Flux behavior. Any future move between Kustomizations should reuse the Phase 2–4 pattern.

### Phase 5: Documentation (PR 5)

Record the observed evidence, the snapshots, and the monitor summary in `docs/validation/`. Update the README structure and the handover only for what was demonstrated.

## k3d clean-bootstrap test

**Purpose:** show, on an empty cluster, whether the GitOps layers converge in dependency order and whether MetalLB custom resources wait for their CRDs.

**Out of scope:** Flux bootstrap and self-management, kube-vip, `ens160`, ARP, and MetalLB L2 announcement. Those belong to a later VMware/K3s test.

**Environment:** WSL with Docker, which is already available on the workstation, plus `k3d` and `kubectl` downloaded at pinned versions into a scratch directory.

```bash
k3d cluster create flux-order-test \
  --image rancher/k3s:v1.36.4-k3s1 \
  --k3s-arg "--disable=servicelb@server:*" \
  --k3s-arg "--disable=traefik@server:*"
# Install the exact Flux components from this repository
kubectl apply --server-side -f clusters/home/flux-system/gotk-components.yaml
kubectl -n flux-system wait deploy --all --for=condition=Available --timeout=5m
```

- If the K3s v1.36.4 image is not published, use the nearest published patch release and record which one.
- servicelb is disabled so that it doesn't compete with MetalLB for LoadBalancer Services.
- The test does not apply `gotk-sync.yaml`. It points to the SSH URL and a deploy-key Secret, neither of which exists in the test. Instead, the test creates a public HTTPS GitRepository with the same name, `flux-system`, so the manifests' `sourceRef` resolves unchanged.

```bash
kubectl apply -f - <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/triley76/home-cluster
  ref:
    branch: <branch under test>
EOF
```

### Negative control (Phase 0)

This checks whether the current single-unit layout fails on an empty cluster.

**Setup:** set `<branch under test>` to `main`, then apply one Kustomization named `layout-control` with path `./clusters/home/infrastructure`, `prune: true`, and `wait: true`.

**Expected:** the Kustomization fails because the `metallb.io` kinds are unknown, so `HelmRelease/metallb` is never created.

**Record:** the exact error from `kubectl -n flux-system describe kustomizations.kustomize.toolkit.fluxcd.io layout-control`.

**If it does not fail:** update the Problems section. The suspected ordering defect is not real in that form, and Phase 3 becomes an organizational change rather than a bootstrap fix.

### Positive test (Phase 3 pre-merge gate)

**Setup:** recreate the cluster from scratch. Set `<branch under test>` to the pushed PR 3 branch, then apply `clusters/home/infrastructure.yaml` and `clusters/home/apps.yaml` from that branch with `kubectl apply -f`.

**Pass criteria:**

- All three Kustomizations reach `Ready=True`.
- The `Ready` transition times are ordered controllers → configs → apps. Get them from `.status.conditions[?(@.type=="Ready")].lastTransitionTime`.
- The `kustomize-controller` logs and events show no unknown-kind or CRD-not-found errors for `metallb.io`. Transient `DependencyNotReady` messages are expected.
- `Service/platform-canary` receives an ingress address from `10.0.0.220-10.0.0.230`. MetalLB allocates from the pool even though no L2 announcement happens in k3d.
- Evidence is recorded on whether kstatus held `apps` until the LoadBalancer address was assigned. This confirms or corrects the readiness table above.

**Afterwards:** `k3d cluster delete flux-order-test`.

**What a pass shows:** that the Git layout converges in dependency order from empty on K3s in k3d.

**What a pass does not show:** Flux self-bootstrap, VMware networking, kube-vip, L2 announcement, ARP behavior, or LAN reachability.

## Evidence boundaries

If Phases 0–4 and the k3d test pass, they show that:

- ownership moved in place without recreating any object;
- Flux manages itself again;
- the ordered Kustomizations reconcile on the existing cluster;
- the layout converges from empty in k3d;
- LAN availability held at the monitor's sample rate during the Phase 3 change window.

They do **not** show:

- a clean bootstrap of the real VMware/K3s cluster, including kube-vip and MetalLB L2;
- zero-downtime behavior outside the monitored window;
- multi-node failure tolerance;
- production readiness.
