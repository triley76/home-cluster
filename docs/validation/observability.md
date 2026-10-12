# Observability validation

## Scope

This record documents the observed results of Phase 3 of the [observability design](../design/observability.md): enabling Grafana, secured, on the three-node V2 K3s cluster, and the k3d rehearsals that gated it.

All evidence below was supplied by the repository owner. It was not independently accessed while this record was prepared. The evidence files are stored outside this repository; they are identified by file name and SHA-256.

This record contains no Grafana credentials, credential-file contents, Secret data, throwaway rehearsal credentials or private keys.

## Implementation

| Item | Value |
| --- | --- |
| Pull request | #14, `feat: enable secured Grafana observability` |
| Merge revision | `f140bc5334ef0746102c4fcf0cc76561a14689ed` |
| Tested implementation commit | `728fde65dc16a7fbbd578e1fb503b5f45a94dcba` |
| Tested tree | `3eb80f16485e440eb69cc1fc298658e02ac5bb27` (the merge revision has the same tree, as Git shows) |
| Chart | `kube-prometheus-stack` `91.8.2`; the Helm release moved from revision 1 to 2 |
| Grafana image | `docker.io/grafana/grafana:13.2.3-distroless` |
| Sidecar image (dashboard and datasource) | `quay.io/kiwigrid/k8s-sidecar:2.11.2` |
| Exposure | Internal only, through a `ClusterIP` Service |
| Admin credentials | The out-of-band Secret `monitoring/grafana-admin`, which is not stored in Git |
| Credential file | Outside this repository, at `/home/ansible/.config/home-cluster/grafana-admin`, mode `600` |

The configuration under test is described in the design: Pod Security `restricted` with `initChownData` disabled, a ConfigMap-only Role for the sidecars, a 1 GiB `local-path` claim, the `Recreate` deployment strategy, and the [resource sizing](../design/observability.md#requests-and-limits) derived from earlier rehearsals.

## Pre-merge k3d rehearsals

Both rehearsals ran on disposable single-node k3d clusters against the exact tested commit and tree, and both passed. Each evidence archive was scanned for the throwaway Grafana password before packaging, and the scan found none.

Earlier rehearsals of earlier commits found the sidecar memory and harness defects that led to the final sizing and the harness corrections. They are not the evidence for the merged commit.

### Clean bootstrap

| Item | Value |
| --- | --- |
| Result | PASS |
| Tested commit / tree | `728fde65dc16a7fbbd578e1fb503b5f45a94dcba` / `3eb80f16485e440eb69cc1fc298658e02ac5bb27` |
| Evidence archive | `k3d-obs-p3-clean-20261009T192214Z.tar.gz` |
| Archive SHA-256 | `926055e150cd461b8fd5ecb149493624e623293f7bb3a986acd7bf1da44e003a` |

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All six became `Ready=True` at the tested revision |
| Pod Security | Grafana ran under the `restricted` profile |
| Authentication | Anonymous API access returned 401; authenticated access returned 200 |
| Provisioning | 25 dashboards and the Prometheus and Alertmanager datasources converged |
| Persistence | Grafana data survived a pod replacement |
| Metrics, RBAC, plugins | Metrics, least-privilege RBAC and plugin-restriction checks passed |
| Phase 3 rollback | Disabling Grafana kept the monitoring layer and the out-of-band Secret. It deleted Grafana's claim, volume and database state, as the design records |
| Re-enable | Re-enabling Grafana created a fresh claim and database |
| Full monitoring-layer removal | Deleted both monitoring namespaces, Grafana's storage and the out-of-band Secret |
| Canary isolation probe | 2,379 requests, zero failures, both replicas responding |
| Containers | No Grafana container restarted or was OOM-killed |

Peak memory after re-enable:

| Container | Peak | Limit |
| --- | --- | --- |
| Grafana | 242 MiB | 512 MiB |
| Dashboard sidecar | 92 MiB | 256 MiB |
| Datasource sidecar | 82 MiB | 256 MiB |

### Phase 2 → Phase 3 upgrade

| Item | Value |
| --- | --- |
| Result | PASS |
| Base revision | `847e2d6d62d9c9875925fd42eb68fd079d3ddef4` |
| Upgraded revision / tree | `728fde65dc16a7fbbd578e1fb503b5f45a94dcba` / `3eb80f16485e440eb69cc1fc298658e02ac5bb27` |
| Evidence archive | `k3d-obs-p3-upgrade-20261011T185349Z.tar.gz` |
| Archive SHA-256 | `c6aaae96a3516787aa014970358f3946ae8f00c9cd6142fb367e804eeefb7495` |

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All six were `Ready=True` before and after the upgrade |
| Helm revisions | `kube-prometheus-stack` moved exactly one revision, from 1 to 2. MetalLB remained at revision 1 |
| Existing pods | All five pre-existing monitoring and node-exporter pods kept their UIDs, and no pre-existing monitoring container restarted |
| New pods | Grafana was the only new long-running pod |
| Prometheus claim | Kept its UID |
| Pod Security | No admission failures |
| Canary probe during the upgrade | 379 requests, zero failures, both replicas responding |

Peak memory:

| Container | Peak | Limit |
| --- | --- | --- |
| Grafana | 228 MiB | 512 MiB |
| Dashboard sidecar | 74 MiB | 256 MiB |
| Datasource sidecar | 74 MiB | 256 MiB |

All six measured peaks across both rehearsals are below the configured requests (Grafana 256 MiB; each sidecar 128 MiB) and limits.

## Live rollout

Merged as `main@sha1:f140bc5334ef0746102c4fcf0cc76561a14689ed`. Flux reconciled the merge automatically; no forced reconciliation was needed.

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All six became `Ready=True` at `main@sha1:f140bc5334ef0746102c4fcf0cc76561a14689ed` |
| Helm release | `kube-prometheus-stack` became `Ready` at revision 2 |
| Grafana Deployment | 1/1 Available |
| Grafana Pod | 3/3 Running, zero restarts |
| Grafana claim | Bound, 1 GiB |
| Prometheus claim | Remained Bound, 10 GiB |
| Anonymous API access | 401 |
| Authenticated API access | 200 |
| Dashboards | 25 |
| Datasources | Alertmanager and Prometheus |

The admin credentials are not managed in Git. They come from the out-of-band `monitoring/grafana-admin` Secret.

## Stability observations

Two separate one-hour windows were recorded. **They were not simultaneous.** Both files are stored outside this repository.

| Observation | File | Window | SHA-256 |
| --- | --- | --- | --- |
| Windows LAN canary monitor | `phase6-grafana-lan-stability-20261011T154611.tsv` | 2026-10-11 15:46:11–16:46:10 EDT | `0AD8DC94645A96AD61E519778B04E333C2E28CDAF23E4446E18CCD2720BC907F` |
| Linux cluster and Grafana monitor | `phase6-grafana-live-stability-20261011T231321Z.tsv` | about 2026-10-11 19:13–20:13 EDT (23:13–00:13 UTC) | `0a0059254ae422a39c82379c93173d543447898d8ab60ef0aae23ad7cd840e35` |

**Windows LAN monitor:**

- 6,771 successful requests and 0 failed requests.
- Both replicas responded: `platform-canary-588665dff4-f5dpg` and `platform-canary-588665dff4-gcthl`.

**No interruption was observed within this window, at the monitor's sample rate.**

**Linux cluster and Grafana monitor:** 0 failed samples. Throughout the window:

- all six Kustomizations stayed `Ready=True` at the merge revision;
- all monitoring pods stayed Ready, and their UIDs were unchanged;
- the monitoring restart total stayed at 6, so no monitoring container restarted during the window;
- the Grafana claim stayed Bound;
- no node reported `MemoryPressure` or `DiskPressure`, and the highest observed node memory utilization was 29%;
- authenticated Grafana checks and canary checks passed.

An earlier attempted Linux monitor was mistakenly run from `rh02`, which had no Kubernetes configuration and tried to reach `localhost:8080`. Its 52 monitor failures came from that placement error, not from the cluster. It is not valid cluster evidence, and its counts are not included above.

## Final live snapshot

| Item | Value |
| --- | --- |
| File | `phase6-grafana-final.txt` |
| Timestamp | `2026-10-12T13:22:49Z` |
| SHA-256 | `e24dc89ca27b449ba8c3896932ba01c2bab33b5bb358e7915526efc42013b196` |

| Check | Observed |
| --- | --- |
| Flux Kustomizations | All six `Ready=True` at the merge revision |
| Helm release | `kube-prometheus-stack` `Ready` at revision 2 |
| Monitoring containers | All Ready |
| Grafana restarts | Zero |
| Grafana claim | Bound, 1 GiB |
| Prometheus claim | Bound, 10 GiB |
| Grafana Service | `ClusterIP` |
| Node memory utilization | 19%–29% |
| Container memory | Grafana 212 MiB; dashboard sidecar 73 MiB; datasource sidecar 72 MiB |

## Evidence boundaries

This evidence establishes that:

- the exact merged tree passed a clean bootstrap and a Phase 2 → Phase 3 upgrade in k3d, including authentication, persistence, provisioning, least-privilege RBAC, plugin restrictions, rollback and full removal;
- in k3d, the upgrade added Grafana without restarting or recreating the existing monitoring pods or the Prometheus claim;
- the live rollout reconciled automatically to Helm revision 2, with Grafana available internally and the admin login working;
- no interruption was observed within the two recorded one-hour windows, each at its own monitor's sample rate.

It does **not** establish:

- zero-downtime behavior in general, or outside the recorded windows;
- production readiness;
- multi-node or highly available Grafana;
- recovery of Grafana's `local-path` volume after the node holding it fails;
- encrypted external access to Grafana; Grafana is not exposed outside the cluster;
- a clean bootstrap of the real VMware/K3s cluster;
- that the admin credentials can be recovered if both the Kubernetes Secret and the protected out-of-band credential file are lost.

The k3d rehearsals run on a single node. They do not test VMware networking, kube-vip, MetalLB L2 behavior or real multi-node failure tolerance.
