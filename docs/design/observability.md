# Design: constrained observability with kube-prometheus-stack

**Status:** Proposed. Design only. Nothing is installed or applied, and no manifests change until this design is reviewed and approved. Each implementation phase below is a separate PR.

This design follows the safety model of the [Flux reconciliation-split design](flux-reconciliation-split.md): evidence first, one coherent change per PR, static validation and a disposable k3d rehearsal before merge, explicit stop conditions and rollback, and documentation limited to what was observed.

## Decisions

| Topic | Decision |
| --- | --- |
| Grafana access | `ClusterIP` only, accessed with `kubectl port-forward`. MetalLB exposure (tentatively `10.0.0.221`) is deferred to a later PR that also addresses authentication and TLS. |
| Alerting | Alert rules are installed and evaluated. Notification delivery is deferred until a destination and a secret-management workflow are approved. |
| Prometheus storage | 10 GiB `local-path` PVC, `retention: 7d`, `retentionSize: 8GB`. `local-path` does not enforce the requested claim size, and Prometheus cannot move while its node-local volume is unavailable. |
| Chart version | `kube-prometheus-stack` `91.8.2` is a **candidate** recorded on 2026-09-30. Release notes are reviewed and the version is re-verified immediately before implementation. This design does not commit to deploying that exact version. |
| node-exporter | Kept. Isolating it in a dedicated privileged namespace is investigated and tested in k3d at implementation time. If the chart cannot do that safely, the broader Pod Security exception for `monitoring` is documented as an accepted lab risk and requires explicit approval. |
| Operator admission webhooks | Kept enabled (chart default). They are disabled only if the k3d rehearsal shows a specific bootstrap failure, and this design must be amended with that evidence before implementation. |
| Alertmanager storage | `emptyDir` initially. A small PVC is reconsidered when notification delivery is enabled. |

## Goals

1. Provide in-cluster metrics, dashboards and alert evaluation for the home cluster. All manifests and Helm releases are Flux-managed. The only exception is the credential Secrets that this design explicitly identifies (currently `monitoring/grafana-admin`), which are created out of band.
2. Make the following visible:
   - node readiness and reboots;
   - container restarts;
   - pod availability;
   - Flux source and Kustomization readiness, and failed reconciliation;
   - MetalLB health;
   - `platform-canary` replica and endpoint availability.
3. Stay small: one replica per component, conservative requests and limits, bounded retention, and no change to existing workloads or to the MetalLB release.
4. Keep credentials and generated secrets out of Git.

## Non-goals

- **Highly available monitoring.** Prometheus, Alertmanager and Grafana each run one replica; Prometheus and Grafana use node-local storage.
- **Alert delivery.** No notification receiver is configured until a destination and secret-management workflow are approved. Alerts are visible only in the Prometheus and Alertmanager UIs.
- **LAN exposure of any monitoring UI in this design.** Grafana, Prometheus and Alertmanager are all `ClusterIP`. Exposure, authentication and TLS belong to a later, separate PR.
- **Long-term or off-cluster metrics storage.** No remote write, Thanos, or Mimir.
- **Logs, traces, or OpenTelemetry.** No Loki, Tempo, or collector.
- **Synthetic LAN probing.** Prometheus observes the cluster from inside. It does not see LAN reachability, ARP, or MetalLB L2 advertisement from a client's point of view; the Windows LAN monitor remains the external check.
- **Monitoring of K3s-embedded control-plane components** (etcd, kube-controller-manager, kube-scheduler, kube-proxy). Their metrics are not exposed on scrapeable endpoints in the default K3s configuration.
- **Changing MetalLB, Flux, or `platform-canary`** to add metrics.

## Current state (recorded live preflight)

Recorded before this design was written. Evidence is stored outside Git at `/home/ansible/flux-split/phase6-observability-preflight.txt`.

| Item | Observed |
| --- | --- |
| Nodes | Three K3s nodes, all `Ready` |
| Allocatable per node | 4 CPUs, 8,131,804 KiB memory (about 7.76 GiB), about 38.9 GB ephemeral storage |
| Current use | 1–2% CPU, 15–19% memory per node |
| Metrics Server | Installed; `kubectl top` works |
| StorageClasses | Only `local-path`: default, provisioner `rancher.io/local-path`, `reclaimPolicy: Delete`, `volumeBindingMode: WaitForFirstConsumer`, expansion disabled |
| PersistentVolumes / claims | None |
| Monitoring workloads | No Prometheus, Grafana, Alertmanager, Loki, Tempo, OpenTelemetry, or exporter workloads |
| Flux HelmReleases | Only `flux-system/metallb` |

Cluster totals for sizing: 12 allocatable CPUs and about 23.3 GiB allocatable memory.

Relevant facts from the repository at `main@sha1:b4ba168ead9e678a7351a5a5402c1d0f67af6175`:

- Flux reconciles in layers: `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `apps`. Normal garbage collection is in effect (`prune: true`, default `deletionPolicy`).
- The MetalLB pool is `10.0.0.220-10.0.0.230`, and `platform-canary` holds `10.0.0.220`.
- `gotk-components.yaml` includes the NetworkPolicy `flux-system/allow-scraping`, which allows ingress on TCP 8080 from any namespace. All four Flux controllers expose metrics on port 8080, named `http-prom`.
- The MetalLB 0.16.1 chart serves controller and speaker metrics only over HTTPS on port 9120 (`metricshttps`), behind a Kubernetes authorization check. This comes from the chart package, not from the live cluster.

## Proposed architecture

```text
                      ┌───────────────────── namespace monitoring ─────────────────────┐
  node-exporter ×3 ──▶│ Prometheus (1 replica, 10 GiB local-path, 7d / 8GB retention)  │
  (namespace: see     │   ▲ PodMonitors: Flux controllers, MetalLB                     │
   Security)          │   │ PrometheusRules: defaults + platform rules                 │
  kubelet/cAdvisor ──▶│   ▼                                                            │
  kube-state-metrics ─▶│ Alertmanager (1 replica, emptyDir, null receiver)  ClusterIP  │
  (incl. Flux CRs)    │ Grafana (1 replica, 1 GiB local-path)              ClusterIP   │
                      │ Prometheus Operator (1 replica, admission webhooks enabled)    │
                      └────────────────────────────────────────────────────────────────┘
```

**Component:** `kube-prometheus-stack`, deployed by a Flux `HelmRelease` from a Flux `HelmRepository`, with an exact chart version and explicit image tags.

### Flux dependency placement

Two new Flux Kustomizations, `monitoring` and `monitoring-configs`, form a separate branch of the dependency graph:

```text
flux-system
  └─ infrastructure-controllers
       └─ infrastructure-configs
            ├─ apps                    (unchanged; does not depend on monitoring)
            └─ monitoring              (kube-prometheus-stack)
                 └─ monitoring-configs (PodMonitors, PrometheusRules, dashboards)
```

Boundaries:

- `monitoring` depends on `infrastructure-configs`.
- `monitoring-configs` depends on `monitoring`.
- `apps` remains independent of monitoring. It keeps its existing `dependsOn: infrastructure-configs`, and nothing is added to it.
- A monitoring failure must not block `apps`. `apps` and `infrastructure-*` must remain independently reconcilable and available while `monitoring` or `monitoring-configs` is failed or suspended.
- This design does **not** claim that a monitoring failure affects only the monitoring subtree's readiness. The root `flux-system` Kustomization applies and owns the `monitoring` and `monitoring-configs` Kustomization objects.
  - As committed on `main`, `gotk-sync.yaml` sets neither `wait` nor `healthChecks` on the root, so its readiness is not expected to depend on the readiness of the child Kustomizations it applies.
  - That expectation is not treated as established. The root's readiness while a monitoring child fails is an explicit k3d rehearsal observation (item 9).

Why this placement:

1. **Keeps a later LoadBalancer exposure safe.** No `LoadBalancer` Service is part of this design. If the stack sat in `infrastructure-controllers`, the later Grafana exposure would deadlock a clean bootstrap:
   - the Service would need an address from the MetalLB pool, which only `infrastructure-configs` applies;
   - that layer waits for `infrastructure-controllers` to be Ready;
   - Helm treats a `LoadBalancer` Service without an address as not ready.

   Placing `monitoring` after `infrastructure-configs` removes that cycle before it can arise.
2. **Keeps workloads independent.** Monitoring is a sibling of `apps`, not a prerequisite of it.
3. **Separates CRDs from their users.** The chart installs the Prometheus Operator CRDs, and PodMonitor and PrometheusRule objects cannot be applied before those CRDs exist. `monitoring-configs` depends on `monitoring` for the same reason that `infrastructure-configs` depends on `infrastructure-controllers`.

Proposed Flux Kustomizations:

| Kustomization | Path | dependsOn | wait | prune | interval / retry / timeout |
| --- | --- | --- | --- | --- | --- |
| `monitoring` | `./clusters/home/monitoring/controllers` | `infrastructure-configs` | true | true | 1h / 2m / 15m |
| `monitoring-configs` | `./clusters/home/monitoring/configs` | `monitoring` | true | true | 1h / 1m / 5m |

The 15-minute timeout on `monitoring` allows for CRD installation, the admission-webhook certificate Jobs, and first-time image pulls. The `HelmRelease` uses its own 10-minute timeout, three install and upgrade remediation retries, and `crds: CreateReplace` on install and upgrade, so chart upgrades also upgrade the CRDs.

## Proposed repository tree

```text
clusters/home/
├── kustomization.yaml              # adds: monitoring.yaml
├── monitoring.yaml                 # Flux Kustomizations: monitoring, monitoring-configs
└── monitoring/
    ├── controllers/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml          # monitoring (+ node-exporter namespace if isolation succeeds)
    │   ├── helmrepository.yaml     # prometheus-community
    │   └── kube-prometheus-stack.yaml   # HelmRelease with pinned chart, images and values
    └── configs/
        ├── kustomization.yaml
        ├── podmonitor-flux.yaml        # Flux controllers, port http-prom
        ├── podmonitor-metallb.yaml     # MetalLB controller and speaker, port metricshttps
        ├── prometheusrule-platform.yaml
        └── dashboards/
            ├── kustomization.yaml      # ConfigMaps labelled grafana_dashboard: "1"
            ├── flux.json
            └── platform.json           # MetalLB and platform-canary
```

Existing paths are not modified, except for the root `clusters/home/kustomization.yaml`, which gains `monitoring.yaml`. The Phase 1 CI guard for `flux-system` still applies.

## Versions (candidate)

These were read from the published chart package on 2026-09-30. They are a **candidate, not a commitment**.

Immediately before the first implementation PR:

1. Review the release notes of the candidate and of every newer release.
2. Choose the version to deploy.
3. Re-read its image defaults from the chart package.
4. Update this table in the implementation PR.

Observability Phase 1 (CI) selected chart `91.8.2` for validation on 2026-09-30. This table is the **approval source for every image reference**: CI requires each enabled image to be pinned explicitly in the `HelmRelease` values (see `scripts/observability-image-pins.yaml`) and to render exactly the full reference approved here.

| Item | Approved reference (2026-09-30) |
| --- | --- |
| Chart `kube-prometheus-stack` | `91.8.2` (published 2026-09-29; package SHA-256 `dbd50ecc4b3c4a0231d8a7c766d4fd8690be4bf2230acb572849fae129797a23`) |
| Prometheus Operator | `quay.io/prometheus-operator/prometheus-operator:v0.94.1` |
| Prometheus config-reloader | `quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1` |
| Operator admission webhook | `quay.io/prometheus-operator/admission-webhook:v0.94.1` (only if `admissionWebhooks.deployment.enabled`; not used by this design) |
| Webhook certificate Jobs | `ghcr.io/jkroepke/kube-webhook-certgen:1.8.9` |
| Prometheus | `quay.io/prometheus/prometheus:v3.15.0-distroless` |
| Alertmanager | `quay.io/prometheus/alertmanager:v0.34.1` |
| Grafana (subchart `13.2.7`) | `docker.io/grafana/grafana:13.2.3-distroless` |
| Grafana sidecar | `quay.io/kiwigrid/k8s-sidecar:2.11.2` |
| Grafana init (chown) | `docker.io/library/busybox:1.38.0` (Grafana `initChownData`, kept for the `local-path` claim; see rehearsal item 8) |
| Grafana test framework | Not deployed: `grafana.testFramework.enabled: false` (no image approved) |
| kube-state-metrics (subchart `8.6.0`) | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` |
| node-exporter (subchart `4.59.0`) | `quay.io/prometheus/node-exporter:v1.12.1-distroless` (chart default distroless variant) |

Rules for this table:

- The chart version is pinned exactly.
- Every image is pinned explicitly in the `HelmRelease` values (registry, repository and tag), so every image change is visible in review.
- Any later chart upgrade updates the chart pin, the image pins and this table in the same PR.

## Proposed configuration

Summary of the `HelmRelease` values. The exact values file is produced in the implementation PR and validated by rendering.

| Area | Setting |
| --- | --- |
| K3s-incompatible scrape targets | `kubeEtcd`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` disabled, together with their default rule groups, to avoid permanently failing targets and false alerts |
| Operator admission webhooks | Enabled (chart default), with the chart's certificate Jobs. See [Decisions](#decisions) for the only condition under which they are disabled |
| Selectors | `podMonitorSelectorNilUsesHelmValues`, `serviceMonitorSelectorNilUsesHelmValues`, `ruleSelectorNilUsesHelmValues` set to `false`, so objects in `monitoring-configs` are selected without the Helm release label |
| Prometheus | 1 replica, `retention: 7d`, `retentionSize: 8GB`, `walCompression: true`, `volumeClaimTemplate` on `local-path` requesting 10 GiB, default 30 s scrape and evaluation intervals |
| Alertmanager | 1 replica, `emptyDir` storage, default configuration with the `null` receiver |
| Grafana | 1 replica, persistence on `local-path` 1 GiB, `admin.existingSecret` referencing an out-of-band Secret, no plugins, anonymous access disabled, dashboard sidecar enabled, `initChownData` kept, `testFramework.enabled: false` (Helm test Pods are not used; CI and the rehearsal provide validation) |
| Services | Grafana, Prometheus and Alertmanager all `ClusterIP`. No `LoadBalancer` Service and no MetalLB address in this design |
| kube-state-metrics | 1 replica. Custom Resource State configuration exporting Flux resources as `gotk_resource_info`, as recommended by the Flux monitoring documentation, with RBAC `extraRules` for the Flux CRDs |
| node-exporter | DaemonSet on all three nodes; chart defaults `hostNetwork`, `hostPID`, and a read-only root filesystem mount. Namespace placement per [Pod Security](#pod-security-and-node-exporter) |

### Scrape targets

| Target | Mechanism | Status |
| --- | --- | --- |
| Nodes | node-exporter, port 9100 on each node | Phase 0 confirms the port is free |
| Kubelet and cAdvisor | Chart `ServiceMonitor` | Expected to work with K3s; rehearsal assertion |
| Kubernetes objects | kube-state-metrics | Nodes, pods, Deployments, DaemonSets, Endpoints/EndpointSlices, Flux custom resources |
| API server, CoreDNS | Chart `ServiceMonitor`s | Kept enabled |
| Flux controllers | `PodMonitor` in `flux-system`, port `http-prom` | Allowed by `allow-scraping` |
| MetalLB | `PodMonitor` in `metallb-system`, port `metricshttps`, HTTPS with the Prometheus ServiceAccount token and **certificate validation against the endpoint's CA** | **Rehearsal assertion, not an established fact** (see below) |

**MetalLB scraping** is expected to work without changing the MetalLB HelmRelease:

- the chart's Prometheus ClusterRole grants `get` on the `/metrics` non-resource URL;
- MetalLB's metrics endpoint authorizes that permission.

This has not been observed. The k3d rehearsal must show MetalLB targets `up`, with the MetalLB release unchanged. If it does not, MetalLB scraping is dropped from the phase, or redesigned in a design amendment. It is never enabled by changing the MetalLB HelmRelease without a separate review.

**TLS verification for MetalLB metrics:**

- **Preferred:** the PodMonitor validates the metrics endpoint against the CA or certificate that MetalLB generates, referenced from its Secret, with the server name set to match the certificate.
- **CA discovery and validation are a rehearsal assertion.** The rehearsal must identify which Secret, if any, holds the CA for the metrics endpoint, and show a successful verified scrape.
  - It is **not** established that MetalLB 0.16.1 stores a CA for its metrics endpoint in a Secret. With the chart default, the endpoint may use a certificate generated in memory at startup.
  - Supplying a certificate through the chart's metrics TLS Secret options would change the MetalLB HelmRelease, and that needs its own reviewed design.
- **Fallback, only with approval:** `insecureSkipVerify` is used only if CA validation cannot be made to work. In that case the weaker verification is documented in the implementation PR and in the validation record, and it is explicitly approved before merge. It is not the default configuration.

`platform-canary` (`traefik/whoami`) exposes no metrics of its own. Its availability is observed through kube-state-metrics.

## Resource, retention and storage estimates

### Requests and limits

| Component | Replicas | CPU request / limit | Memory request / limit |
| --- | --- | --- | --- |
| Prometheus | 1 | 200m / 1 | 1 GiB / 2 GiB |
| Prometheus config-reloader | 1 | 10m / 50m | 32 MiB / 64 MiB |
| Prometheus Operator | 1 | 50m / 200m | 64 MiB / 256 MiB |
| Alertmanager (+ reloader) | 1 | 35m / 150m | 96 MiB / 192 MiB |
| Grafana (+ sidecar) | 1 | 70m / 300m | 192 MiB / 640 MiB |
| kube-state-metrics | 1 | 25m / 100m | 64 MiB / 256 MiB |
| node-exporter | 3 | 25m / 100m each | 32 MiB / 64 MiB each |
| **Total** | | **≈ 465m / ≈ 2.1 CPU** | **≈ 1.5 GiB / ≈ 3.6 GiB** |

The admission-webhook certificate Jobs are short-lived and not included.

As a share of the cluster's 12 CPUs and about 23.3 GiB of memory:

| Measure | CPU | Memory |
| --- | --- | --- |
| Requests | about 4% | about 7% |
| Limits | about 18% | about 15% |

Current use is 15–19% memory per node. The node hosting Prometheus is expected to rise by about 1–2 GiB.

These figures are starting points. After deployment they are checked against observed usage (`kubectl top`, `container_memory_working_set_bytes`) before being treated as settled.

### Prometheus storage

Configuration: a 10 GiB `local-path` claim, `retention: 7d`, and `retentionSize: 8GB`. Whichever limit is reached first applies.

Assumptions for the estimate:

- 50,000–150,000 active series, which is typical for kube-prometheus-stack defaults on three nodes with a handful of workloads;
- 30 s scrape interval;
- about 1.5 bytes per compressed sample.

| Active series | Samples/s | 7-day block data | With WAL and head (≈ +1–2 GB) |
| --- | --- | --- | --- |
| 50,000 | ≈ 1,700 | ≈ 1.5 GB | ≈ 3 GB |
| 150,000 | ≈ 5,000 | ≈ 4.5 GB | ≈ 6.5 GB |

The actual series count is measured after deployment with `prometheus_tsdb_head_series`.

**`local-path` does not enforce the requested claim size.** The provisioner creates a directory on the node's disk, and does not impose a quota. The 10 GiB request is a planning figure. The real limit on Prometheus's disk use is `retentionSize: 8GB`, and beyond that, only the node's free disk space.

Other storage:

| Component | Storage | Consequence |
| --- | --- | --- |
| Grafana | 1 GiB `local-path` claim, holding users, preferences, and the SQLite database. Dashboards are provisioned from Git. | Same node-local limits as Prometheus |
| Alertmanager | `emptyDir` | Silences and notification state are lost on restart. A small claim is reconsidered when notification delivery is enabled. |

`local-path` volumes use the node's root filesystem, which is the same disk as the roughly 38.9 GB of allocatable ephemeral storage. Phase 0 records free space on each node's `local-path` directory.

## Storage limitations

These limitations are accepted for this design and must stay visible in documentation:

- **`local-path` is node-local.** Each volume lives on one node, and its pod is pinned to that node by volume node affinity.
- **Prometheus cannot move while its node-local volume is unavailable.** If the node holding the Prometheus volume fails or is down, Prometheus stays `Pending` until that node returns. Metrics are not collected in the meantime, and stored metrics are unavailable. The same applies to Grafana.
- **A lost node disk means lost data.** Stored metrics and Grafana state are lost.
- **The claim size is not enforced**, as described above.
- **PVC expansion is disabled.** Growing Prometheus storage means a new claim, and the previous data is lost unless it is copied manually.
- **`reclaimPolicy: Delete`.** Deleting a claim deletes its data.
- **Claims can outlive the release.** Prometheus's claim is created by a StatefulSet `volumeClaimTemplate`, so it is not removed when the HelmRelease is uninstalled. It must be deleted manually, which then deletes its data.
- **Grafana's claim lifecycle is not assumed.** It is created differently from Prometheus's, and it may or may not be deleted with the release. The implementation inspects the rendered chart and tests it in the rehearsal (see [Rollback](#rollback)).
- **This is not HA monitoring.** Monitoring is least available exactly when a node fails.

## Security and credential handling

- **Nothing secret in Git.** No passwords, tokens, API keys, webhook URLs, or generated secrets are committed.
- **Grafana admin credentials:** a Secret `monitoring/grafana-admin`, with keys `admin-user` and `admin-password`, is created out of band before Grafana is enabled. The password is generated on the operator's workstation and stored in the owner's password manager. The `HelmRelease` references it with `admin.existingSecret`.
  - The Secret is not in any Flux inventory, so Flux will neither create nor prune it. Deleting the `monitoring` namespace would delete it.
  - Migrating it to an encrypted or external secret workflow is part of the pending secret-management work in [SECURITY.md](../../SECURITY.md).
- **Chart-generated secrets** (for example, Alertmanager configuration and the admission-webhook certificates) are created in the cluster and never exported to Git.
- **Exposure:** none on the LAN.
  - Grafana, Prometheus and Alertmanager are `ClusterIP`, reached with `kubectl port-forward` by someone who already holds cluster credentials.
  - Grafana still requires its admin login.
  - Anonymous access, sign-up, and plugin installation are disabled.
- **RBAC:**
  - Prometheus receives the chart's standard cluster-wide read access for discovery.
  - kube-state-metrics receives read access to the Flux custom resources it reports on.
  - No write access to cluster resources is added.

### Pod Security and node-exporter

node-exporter needs `hostNetwork`, `hostPID`, and `hostPath` mounts, which only the `privileged` Pod Security level allows.

**Preferred: isolate node-exporter in a dedicated privileged namespace.** Only that namespace gets `enforce: privileged`. `monitoring` gets `enforce: restricted`, or `baseline` if the rehearsal shows another component needs it.

The candidate chart exposes `prometheus-node-exporter.namespaceOverride`. Whether using it is safe is **not established**. At implementation time, the investigation and the k3d rehearsal must show that:

- the node-exporter DaemonSet, Service and ServiceAccount are created in the dedicated namespace, and nothing else is;
- the node-exporter scrape configuration follows it, with all three node targets `up`;
- the default node alert and recording rules and the node dashboards still receive data;
- no other component needs `privileged`, and `monitoring` admits every other pod at the chosen level;
- uninstalling or pruning cleans up both namespaces as expected.

**Fallback: a namespace-wide exception, only with explicit approval.** If isolation cannot be shown to work safely:

- `monitoring` is labelled `enforce: privileged`, with `audit` and `warn` at `restricted`, so any other pod that would violate `restricted` is still reported;
- this is documented as an **accepted lab risk**;
- it requires explicit approval, recorded in the implementation PR, before merge.

In either case, `platform-demo` stays `restricted`.

## Dashboards and alerts

### Dashboards

| Dashboard | Source |
| --- | --- |
| Nodes, compute resources, pods, workloads | Chart defaults (kube-prometheus-stack dashboards) |
| Flux cluster and control-plane | Flux's `flux2-monitoring-example`, pinned to a specific commit, license recorded, stored as JSON under `monitoring/configs/dashboards/` |
| Platform | Custom: MetalLB controller and speaker health, address allocation, `platform-canary` replicas and endpoints |

### Alerts

Alert rules are installed and evaluated. **Notification delivery is deferred.** Alertmanager runs with the default `null` receiver, so alerts are visible in the Prometheus and Alertmanager UIs only.

The chart's default rules are kept, except for the rule groups tied to the disabled K3s-embedded components. Node readiness and Deployment availability are covered by these defaults, not by duplicate custom rules:

- `KubeNodeNotReady`
- `KubeDeploymentReplicasMismatch`
- `KubePodCrashLooping`, `KubePodNotReady`
- `KubeDaemonSetRolloutStuck`
- `TargetDown`, `Watchdog`

If the rehearsal shows that a default rule relied on here is absent or unsuitable in the chosen chart version, the implementation PR must make a reviewed adjustment. A duplicate rule is not pre-installed.

Platform rules added in `prometheusrule-platform.yaml`:

| Alert | Expression (proposed) | For | Severity |
| --- | --- | --- | --- |
| `NodeRebooted` | `changes(node_boot_time_seconds[15m]) > 0` | – | info |
| `ContainerRestarted` | `increase(kube_pod_container_status_restarts_total[15m]) > 0` | – | warning |
| `FluxResourceNotReady` | `gotk_resource_info{ready!="True",suspended="false"}` | 10m | critical |
| `FluxResourceSuspended` | `gotk_resource_info{suspended="true"}` | 1h | info |
| `FluxReconcileErrors` | `increase(controller_runtime_reconcile_errors_total{namespace="flux-system"}[15m]) > 0` | – | warning |
| `MetalLBTargetDown` | `up{job=~".*metallb.*"} == 0` | 5m | critical |
| `MetalLBSpeakerNotReady` | `kube_daemonset_status_number_ready{namespace="metallb-system"} < kube_daemonset_status_desired_number_scheduled{namespace="metallb-system"}` | 5m | critical |
| `CanaryReplicasUnavailable` | `kube_deployment_status_replicas_available{namespace="platform-demo",deployment="platform-canary"} < 2` | 5m | warning |
| `CanaryEndpointsUnavailable` | ready endpoint count for `platform-demo/platform-canary` below 2 | 5m | warning |

**The exact metric names and label values are rehearsal assertions, not established facts.** They include:

- the kube-state-metrics endpoint/EndpointSlice metric, and whether its collector must be enabled;
- the Flux `gotk_resource_info` label values;
- `controller_runtime_reconcile_errors_total` for the Flux controllers;
- every MetalLB-derived series.

Each is confirmed against the chosen versions in the k3d rehearsal, and adjusted in the implementation PR if it differs. A rule whose metric cannot be confirmed is left out rather than shipped unverified.

## Implementation plan (one PR per phase)

| Phase | PR content | Changes to live cluster |
| --- | --- | --- |
| 0 | None: live preflight and baseline; version re-verification and release-note review | None |
| 1 | CI only: render the `HelmRelease` values with the chosen chart (`helm template`) and schema-validate the output; check PrometheusRule syntax with `promtool`; validate that dashboard files parse as JSON | None |
| 2 | `monitoring.yaml` (both Kustomizations), `monitoring/controllers/` with the Namespace(s), HelmRepository and HelmRelease, with **Grafana disabled**; an empty `monitoring/configs/`; root kustomization adds `monitoring.yaml`. The Pod Security approach from the node-exporter investigation is included, or the accepted-risk approval is recorded. | Installs Prometheus Operator (with admission webhooks), Prometheus, Alertmanager, kube-state-metrics, node-exporter |
| 3 | Out of band first: create `monitoring/grafana-admin`. Then the PR enables Grafana, with persistence and a `ClusterIP` Service. | Adds Grafana; no LAN exposure |
| 4 | `monitoring/configs/`: PodMonitors for Flux and MetalLB (MetalLB only if the rehearsal assertion held), platform PrometheusRules limited to verified metrics, dashboards; kube-state-metrics Flux custom-resource configuration in the HelmRelease values | Adds scrape targets, rules, dashboards; Helm upgrade of the monitoring release only |
| 5 | Documentation: validation record with observed evidence and boundaries | None |
| Later, separate designs | Grafana exposure through MetalLB (tentatively `10.0.0.221`) with authentication and TLS; notification receiver, once a destination and secret-management workflow are approved; a possible Alertmanager claim at the same time | – |

Phases 2–4 change only the new `monitoring` subtree, plus the root reference in Phase 2. None of them modifies `infrastructure-*`, `apps`, the MetalLB release, or `flux-system`.

**Precondition for Phase 2:** if the k3d rehearsal shows that admission webhooks cause a specific bootstrap failure, Phase 2 does not proceed with them disabled. This design is first amended with that evidence, and the amendment is reviewed.

## Pre-merge validation

### Static (every PR)

- Existing CI: gitleaks, yamllint, Kustomize render, and kubeconform, including the `flux-system` root guard. The pinned CRD catalog already contains the Prometheus Operator schemas (`PodMonitor`, `ServiceMonitor`, `PrometheusRule`, `Prometheus`, `Alertmanager`).
- From Phase 1:
  - `helm template` of the chosen chart with the proposed values, validated with kubeconform;
  - `promtool check rules` on the PrometheusRule groups;
  - a JSON parse of every dashboard.
- Checks that no Secret or credential-like value appears in `monitoring/`, and that every image tag in the values is explicit.

Static checks do not show scheduling, storage binding, scrape success, webhook behavior, or rule behavior.

### Disposable k3d rehearsal (before Phases 2–4 merge)

This reuses the proven harness from the reconciliation-split work: a disposable, uniquely named cluster; K3s `v1.36.4-k3s1`; Flux components from the tested commit; a Git mirror so the real root self-manages; no automatic deletion; and scoped NAT cleanup.

It must show:

1. From an empty cluster, all six Flux Kustomizations become `Ready=True` at the tested revision, in dependency order, **with admission webhooks enabled**. Any bootstrap failure attributable to the webhooks is recorded as evidence for a design amendment, not worked around silently.
2. The Prometheus and Grafana claims bind through `local-path`, which k3d provides.
3. Prometheus targets are `up` for node-exporter, kubelet, and kube-state-metrics.
4. **MetalLB assertion:**
   - MetalLB controller and speaker targets are `up` through HTTPS and ServiceAccount authorization, and the MetalLB HelmRelease revision is unchanged.
   - The rehearsal records whether a CA or certificate Secret for the metrics endpoint exists, and whether the scrape succeeds with certificate validation.
   - If only `insecureSkipVerify` works, that result is recorded for the approval described under [Scrape targets](#scrape-targets).
5. **Flux assertion:** `gotk_resource_info` reports every Flux Kustomization, GitRepository, and HelmRelease, with the expected label values.
6. **Metric-name assertion:** every platform rule expression returns data, or is removed. All PrometheusRules load without errors, and deleting a canary pod raises the expected alert state.
7. **node-exporter isolation:** the checks listed under [Pod Security](#pod-security-and-node-exporter), with the outcome recorded either way.
8. Grafana answers through `kubectl port-forward` and loads the provisioned dashboards. No `LoadBalancer` Service exists in the `monitoring` namespaces. The Grafana claim's behavior when Grafana is disabled, and when the release is uninstalled, is recorded (see [Rollback](#rollback)). The rehearsal also records whether the fresh `local-path` claim actually needs the `initChownData` permissions initializer (initial ownership of the claim directory, and whether Grafana starts with the initializer disabled). The initializer is removed later only with evidence that Grafana starts successfully on a fresh claim without it.
9. **Independence:** run two cases, `monitoring` suspended, and separately `monitoring` deliberately failing (for example, an invalid chart version on a test branch). In both cases, the rehearsal must show that `apps` and `infrastructure-*`:
   - reconcile a new revision independently;
   - remain `Ready`;
   - keep the canary available through its ClusterIP.

   The rehearsal also **records the root `flux-system` Kustomization's readiness** during the failing case: whether it stays `Ready` or becomes `NotReady` while `apps` remains `Ready` and available. Either outcome is documented. If the root becomes `NotReady`, the implementation PR must describe the operational effect before merge.

Evidence boundaries: k3d runs a single node, with no MetalLB L2 announcement, ARP, `ens160`, or LAN reachability. Resource use in k3d is not representative of the live cluster.

## Live preflight, stop conditions and rollback

### Phase 0: preflight (read-only)

| Check | Pass condition |
| --- | --- |
| Baseline snapshot (object UIDs, owners, MetalLB Helm revision, Kustomization readiness and inventories, pod UIDs and restart counts, service address and L2 owner), taken with the snapshot procedure from the split design, extended to list any `monitoring` objects | All existing Kustomizations `Ready=True` |
| Version re-verification | Chart version chosen after release-note review; image defaults re-read |
| Port 9100 on each node | Free for node-exporter |
| Free space in each node's `local-path` directory | At least 15 GB |
| Recovery point | A K3s etcd snapshot, taken and recorded |
| LAN monitor | Running and clean before each merge |

### Stop conditions (after any monitoring merge)

| Observation | Action |
| --- | --- |
| Any existing Kustomization (`flux-system`, `infrastructure-*`, `apps`) not `Ready` | Revert the PR |
| Any change to the seven platform object UIDs, or MetalLB Helm revision not 2 | Suspend `monitoring` and `monitoring-configs`; investigate before anything else |
| Sustained LAN monitor failures to `10.0.0.220` (more than 30 s) | Revert the PR |
| Node `MemoryPressure` or `DiskPressure` | Revert the PR |
| Node memory above 85% for 10 continuous minutes and attributable to the monitoring rollout | Revert the PR |
| Any `LoadBalancer` Service or new MetalLB allocation appears in the monitoring namespaces | Revert the PR (outside this design's scope) |
| `monitoring` not `Ready` after 20 minutes | Investigate. Other layers are unaffected by design; revert if the cause is not quickly fixed. |

Suspending `monitoring` stops reconciliation, but it does not stop running pods. Reverting is the way to remove load.

### Rollback

- **Revert the phase's PR.** With normal garbage collection, Flux prunes the removed objects, and pruning the `HelmRelease` uninstalls the release.
- **Manual cleanup after uninstalling:**
  - The Prometheus claim from the StatefulSet `volumeClaimTemplate` remains, and must be deleted manually. That deletes its data.
  - **Grafana's claim is not assumed to behave like Prometheus's.** The implementation inspects the rendered manifests of the chosen chart (the claim template and any `helm.sh/resource-policy` annotation). The k3d rehearsal records two cases:
    1. Grafana is disabled in the values (a Helm upgrade).
    2. The release is uninstalled.

    In each case it records whether the Grafana claim is retained or deleted, and the resulting data-loss behavior. Deletion loses Grafana users, preferences and database state; provisioned dashboards return from Git. That observed behavior is written into the implementation PR and the validation record before Phase 3 merges.
  - The Prometheus Operator CRDs remain after uninstall. Deleting them deletes every object of those kinds, and is a separate, deliberate step.
  - The out-of-band `grafana-admin` Secret remains until it is deleted, or the namespace is removed.
- **Scope of a rollback:** it removes monitoring only. It does not touch `infrastructure-*`, `apps`, or MetalLB.

### Post-merge validation (each phase)

- A snapshot comparison shows no change to existing objects, their UIDs, or the MetalLB Helm revision.
- All Kustomizations are `Ready=True` at the merge revision.
- The monitoring pods are Ready, and the claims are Bound, on the recorded nodes.
- Prometheus targets are `up`, and rules are loaded (Phases 2 and 4).
- Grafana is reachable through `kubectl port-forward`, and the admin login works (Phase 3). No `LoadBalancer` Service exists.
- The LAN monitor to `10.0.0.220` stayed clean through the change window.
- Observed CPU and memory are recorded against the estimates above.

## Evidence boundaries and claims not to make

Once implemented and validated, the evidence may support:

- in-cluster metrics collection, dashboards, and rule evaluation for the verified signals;
- no observed effect on the existing platform objects during each rollout;
- measured resource use at the time of validation.

Do **not** claim:

- highly available monitoring, or monitoring that survives the loss of the node holding Prometheus;
- alert delivery or notification, until a receiver exists and a test notification has been received;
- durable or backed-up metrics;
- that absence of an alert means the platform is healthy, particularly for LAN reachability or MetalLB L2 behavior, which Prometheus cannot observe from outside;
- MetalLB scraping, or any specific metric name, before the rehearsal has confirmed it;
- that the candidate chart version is the deployed version, before implementation records it;
- zero-downtime behavior, production readiness, or multi-node failure tolerance;
- that the resource or storage estimates are accurate before they are measured.

## Open items

1. **Notification destination and secret-management workflow.** Both must be approved before any receiver is configured. Until then there is no alert delivery, and no dead-man's-switch that notifies anyone. Reconsider an Alertmanager claim at the same time.
2. **Grafana LAN exposure.** A later design covering MetalLB exposure (tentatively `10.0.0.221`), authentication, and TLS, likely tied to the ingress-controller decision.
3. **node-exporter namespace isolation outcome.** Decided by the implementation-time investigation and k3d rehearsal. The fallback requires explicit approval of the accepted lab risk.
4. **Final chart version.** Chosen immediately before implementation, after release-note review.
5. **Admission webhooks.** Stay enabled, unless rehearsal evidence of a specific bootstrap failure leads to a reviewed design amendment.
