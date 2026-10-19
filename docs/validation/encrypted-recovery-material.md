# Encrypted recovery material validation

## Scope

This record documents the observed results of Stage 2 of the [backup and disaster recovery design](../design/backup-disaster-recovery.md): encrypting the recovery material with `age`, uploading it with the routine role, verifying it, and keeping an inventory of it. The work followed the [encrypted recovery material runbook](../runbooks/encrypted-recovery-material.md).

It also documents a cluster incident that interrupted the work, and the cluster's restoration from a local etcd snapshot.

All evidence below was supplied by the repository owner. It was not independently accessed while this record was prepared.
- Sanitized evidence files are stored outside this repository and identified by file name and SHA-256.
- Results without an evidence file were observed in terminal output. Private receipts for them were retained outside Git.
- Raw transcripts and receipts are not stored in Git.

This record contains none of the following:
- AWS account IDs, ARNs, principal or session identities;
- bucket names or S3 version IDs;
- usernames;
- removable-drive serial numbers, drive letters, capacities or storage locations;
- passwords, passphrases, private identities or plaintext credentials;
- receipt contents, or any digest of plaintext recovery material.

## Summary

| Item | Result |
| --- | --- |
| Work window | 2026-10-16 to 2026-10-19 UTC; final plaintext cleanup completed 2026-10-19 |
| `age` v1.3.2 on `k3s01` and on the administrative workstation (WSL) | Installed and validated |
| Recovery A and Recovery B | Prepared and validated |
| K3s server token | Encrypted, uploaded, downloaded by exact version, and verified against the live source: `MATCH` |
| Grafana administrator credential | Encrypted, uploaded, downloaded by exact version, and verified against the live source: `MATCH` |
| Filled recovery-material inventory | Prepared only in a private tmpfs; encrypted, uploaded, downloaded by exact version, and verified: `MATCH`; copied to Recovery A and Recovery B and verified on both |
| Plaintext and temporary staging | Removed; the live sources remain in place |
| Cluster incident | The first server's local Kubernetes API became unavailable during the work. The cluster was restored from the fresh Stage 2 local etcd snapshot and validated healthy on all three nodes. Root cause not determined |

Stage 2 is complete as defined by the runbook. What it does not show is listed under [What this record does not show](#what-this-record-does-not-show).

## Implementation

| Item | Value |
| --- | --- |
| home-cluster helpers | Reviewed `main` commit `646b6e203e1d67c67fd5a041be1cecca8d958fa1`, after pull request #19 was merged |
| homelab-k3s recovery tools | Implementation commit `4d926d3011cec9d204d822c07db177d104ca28fb`, merged into `main` by pull request #3 (merge commit `5514234`) |
| Routine AWS access | The `HomeClusterBackupOperator` role only |
| Object keys | `recovery/<item>/<date>.age`, for the items `k3s-server-token`, `grafana-admin` and `recovery-inventory` |

## Prerequisites

| Prerequisite (runbook) | Observed |
| --- | --- |
| Fresh on-demand local etcd snapshot before the live workflow | Created; snapshot creation and listing verification passed. Referred to below as the fresh Stage 2 snapshot |
| `age` v1.3.2 on every host that runs `encrypt` or `verify` | Met on `k3s01` and on WSL, before any plaintext verification |
| No active swap during plaintext processing | Met on WSL (below), and before plaintext verification |
| Exact `--limit k3s01` for the recovery-tools installation | Preserved |
| Routine role for every AWS operation | `check-role` printed `PASS` for every accepted AWS workflow |

The record does not show whether the runbook's separate `/dev/tty` rehearsal, with a throwaway identity archive, was performed. Each `verify` against a live source with the real identity archive reported `MATCH`.

## age v1.3.2

### `k3s01`

| Check | Observed |
| --- | --- |
| Installation | `configure-recovery-tools.yml` with exactly `--limit k3s01` |
| Download and SHA-256 verification | Passed |
| Extracted binaries before any destination change | Both were regular files, not symbolic links. Both ran from the private working directory and reported exactly `v1.3.2` |
| Installed binaries | Root-owned regular files, mode `0755`, not symbolic links |
| Final validation | Passed |
| Second configuration run | `changed=0` |
| Separate validation playbook | `changed=0` |

### Administrative workstation (WSL)

| Check | Observed |
| --- | --- |
| Archive | The pinned Linux amd64 `age` v1.3.2 archive, with its pinned SHA-256 verified |
| Extracted binaries | Both validated before installation |
| Installed binaries | `/usr/local/bin/age` and `/usr/local/bin/age-keygen` reported exactly `v1.3.2` |
| Round trip | A byte-for-byte encryption and decryption round trip passed |

### Evidence

| File | SHA-256 |
| --- | --- |
| `phase7-recovery-tools-k3s01-apply-20261016T183053Z.txt` | `0ed8b9ce2f5e441bee38ff418b9e193f389c8d3e6be0095a96d074a48f456828` |
| `phase7-recovery-tools-k3s01-validate-20261016T190101Z.txt` | `9b402d3c683145256dba3473d203fcad9462da97541771a045e89000e1af28e6` |
| `phase7-recovery-tools-k3s01-idempotence-20261016T190101Z.txt` | `f6922e46251c99d6dd24dbf74d01a7f07c136177da39f1248f451f2a28a94a17` |

## Recovery A and Recovery B

| Check | Observed |
| --- | --- |
| Media | Two separate removable drives |
| Encryption | BitLocker AES-256 with a password protector; fully encrypted; protection On; automatic unlock disabled |
| Removal, reinsertion and manual unlock | Passed for each |
| Non-secret write and read verification | Passed for each |
| Recovery B | Needed a full NTFS reformat and an offline filesystem check before its final, successful BitLocker validation |
| Private `age` identity | Verified independently |
| Passphrase-encrypted identity archive | Verified byte-for-byte; ciphertext SHA-256 `202e17734bb08e56be97a4ee30049f0f17875ff688714cfb6ced2840080a602e` |

## Recovery-material results

| Item | Ciphertext SHA-256 | Upload | Version ID captured privately | Exact-version download | Downloaded = uploaded ciphertext | Verification | `cmp -s` exit status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `k3s-server-token` | `e37433d21e64d73d77ec4e779bc045bac9e2ce7eb1ceaf7bd8e307de1697f679` | PASS | PASS | PASS | PASS | `MATCH` against the live source | 0 |
| `grafana-admin` | `32094abd450ced860cc631b08a8d82f4037b4e10cc35349bf45fd7ef921dd9fc` | PASS | PASS | PASS | PASS | `MATCH` against the live source | 0 |
| `recovery-inventory` | `e07635e7ffff651a8c3ccc1525c73c20b4281335bcf84215faa0bbac975598e8` | PASS | PASS | PASS | PASS | `MATCH` against the restored plaintext (below) | 0 |

The filled inventory:
- was created only in a private WSL tmpfs;
- has 43 populated fields and 0 remaining placeholders;
- produced no findings from the recovery-material scanner;
- was verified by restoring the plaintext into a newly created private tmpfs, then checking the downloaded inventory against that restored plaintext independently.

No recovery plaintext was sent to AWS or to cloud-synchronized storage. Only `age` ciphertext was uploaded or copied off-node.

## Inventory copies on the recovery media

| Copy | Size | SHA-256 | Comparison | Afterwards |
| --- | --- | --- | --- | --- |
| Recovery A | 5080 bytes | `e07635e7ffff651a8c3ccc1525c73c20b4281335bcf84215faa0bbac975598e8` | PASS | Explicitly locked successfully, then removed |
| Recovery B | 5080 bytes | `e07635e7ffff651a8c3ccc1525c73c20b4281335bcf84215faa0bbac975598e8` | PASS | Safely ejected; disconnection locked it |

Recovery B could not be locked explicitly, because `Lock-BitLocker` returned a removable-media error. It remained fully encrypted, with protection On, AES-256, a password protector and automatic unlock disabled, and it was safely ejected.

## Cleanup

### `k3s01`

| Check | Observed |
| --- | --- |
| Encrypted working files | Three removed |
| Copied helper and public-recipient working tree | Removed |
| Verification staging files | Removed |
| Recovery-material tmpfs | Absent |
| Live source files | Still present |
| K3s service and API after cleanup | Healthy |

### Administrative workstation (WSL)

| Check | Observed |
| --- | --- |
| Plaintext inventory | Removed |
| Inventory tmpfs | Absent after cleanup |
| WSL swap | Still disabled |
| Encrypted inventory copies | The original and the downloaded copies were retained. They match each other byte-for-byte, and both match the inventory ciphertext SHA-256 above |

## WSL swap

- **Configuration:** swap was disabled with `swap=0` under `[wsl2]` in `.wslconfig`, followed by a WSL shutdown and restart.
- **During processing:** `swapon --show` showed no active swap entry while recovery material was processed.
- **At the end:** the final cleanup confirmed again that no swap was active.

This covers swap inside WSL only. Paging of the WSL virtual machine's memory by the Windows host is the residual risk recorded in the runbook.

## Fresh Stage 2 snapshot

| Item | Observed |
| --- | --- |
| Snapshot | A fresh on-demand local etcd snapshot, taken before the live workflow |
| Creation and listing verification | Passed |
| Evidence | `phase7-stage2-etcd-snapshot-20261016T205541Z.txt`, SHA-256 `441b44e403cc3a88a19ab983ebcbb7d40b17e03963b526c7278c7a5c38e69a4a` |

## Cluster incident and recovery

### Observations

1. During the live work, after a temporary swap-state change on the first control-plane node, that node's local Kubernetes API became unavailable.
2. K3s services then entered restart and failure behavior.

The timing links the two events, but the underlying root cause was **not determined**. This record does not attribute the failure to the swap-state change. Recovery-material plaintext was not involved.

### Recovery

1. Recovery-material work was paused.
2. All K3s services were stopped before recovery.
3. The server token was confirmed identical on all three servers, by comparison only. No fingerprint is recorded.
4. The fresh Stage 2 snapshot was revalidated before use.
5. Two encrypted recovery snapshots were preserved off-node before the restoration ([below](#encrypted-off-node-snapshots)).
6. The first server was restored from the fresh Stage 2 snapshot.
7. The old database directories of the other two servers were moved aside and preserved, and those servers then rejoined.

Exactly two named pre-restore peer database directories are confirmed preserved. No third preserved database directory is claimed.

The preserved database directories and recovery snapshots are kept. **They are not deleted without separate approval.**

### Post-recovery validation

| Check | Result |
| --- | --- |
| All three K3s services active | PASS |
| All three nodes `Ready` | PASS |
| Kubernetes API ready | PASS |
| All three local etcd endpoints healthy | PASS |
| Three-member etcd topology | PASS |
| No non-running pods | PASS |
| All running pod containers ready | PASS |
| Deployments, StatefulSets and DaemonSets healthy | PASS |
| Flux Kustomizations `Ready` | PASS |
| Flux GitRepository `Ready` | PASS |
| Canary workload healthy | PASS |
| Grafana and monitoring workloads healthy | PASS |
| Persistent volumes and claims `Bound` | PASS |

The recovery-material work then continued.

### Post-recovery snapshot

A post-recovery local etcd snapshot was created only after all three nodes and the cluster were healthy.

| Item | Value |
| --- | --- |
| Evidence | `k3s-post-recovery-snapshot-20261018T195304Z.txt`, SHA-256 `a9700eca78eac05f9c4d0deec89b6ad6704170b1a26bcafb81954596d574da0b` |
| Encrypted copy | Ciphertext SHA-256 `d751e3f3d0401450199557782038718b129bab769dad4ad954a28d83af539a86`; compared successfully in private WSL storage and in cloud-synchronized off-node storage |

### Encrypted off-node snapshots

| Snapshot | Ciphertext SHA-256 | Comparisons |
| --- | --- | --- |
| Pre-restoration, first | `a1e3a2eaf8cfe8ddde06562fa2cb870eea0566ba4cafc9d382d3a29157ce7859` | Passed after transfer into private WSL storage, and after copying into cloud-synchronized off-node storage |
| Pre-restoration, second | `227a5f4d0c4845f23cbb811c59b123e20d0e4f78c926ce89fcc5ba3da64ef4fd` | Passed after transfer into private WSL storage, and after copying into cloud-synchronized off-node storage |
| Post-recovery | `d751e3f3d0401450199557782038718b129bab769dad4ad954a28d83af539a86` | Passed in private WSL storage and in cloud-synchronized off-node storage |

These are manually preserved `age` ciphertexts. They are not the design's Stage 4 S3 uploads, which still require Stage 3 secrets encryption first.

## Human access gate

The design's [human access gate](../design/backup-disaster-recovery.md#implementation-plan-one-concern-per-pr) requires that the routine permission set exists and has been used successfully for a recovery-material upload, an inventory check and a rehearsal download. The design's [human access](../design/backup-disaster-recovery.md#human-access) table defines inventory checks as listing objects and versions, reading bucket configuration, or reading the IAM credential report. It defines rehearsal downloads as downloading objects and selected versions.

| Condition | Observed | Source |
| --- | --- | --- |
| The routine permission set exists | Yes: `HomeClusterBackupOperator` | [AWS backup foundation validation](aws-backup-foundation.md) |
| Used successfully for a recovery-material upload | Yes: all three items uploaded with the routine role; `check-role` printed `PASS` for every accepted AWS workflow | This record |
| Used successfully for an inventory check | Yes, as a bucket-configuration read: on 2026-10-15 the routine role read the bucket's versioning (`Enabled`). No object or version listing, and no credential-report read, is recorded with the routine role | [AWS backup foundation validation](aws-backup-foundation.md#routine-role-test) |
| Used successfully for a rehearsal download | Yes: each of the three items was downloaded by its exact S3 version with the routine role, and each download matched the uploaded ciphertext byte-for-byte | This record |
| Routine actions did not use `AdministratorAccess` | Yes: only the routine role was used for Stage 2 AWS operations | This record |

Every stated condition of the gate has been observed. The gate is a precondition for scheduled backup operation, not proof of it. No backup schedule exists yet (Stages 4 and 5).

## Deviations and qualifications

- **AWS CLI path.** The AWS CLI used from WSL was a private wrapper around the authenticated Windows AWS CLI. The wrapper normalized Windows carriage returns, and converted WSL absolute paths for the Windows CLI's file operations. The repository's S3-helper tests use a stub AWS CLI and do not cover this wrapper.
- **The incident.** It interrupted the sequence. A snapshot restoration was needed before the workflow continued, and the root cause remains undetermined.
- **Recovery B lock.** Recovery B could not be locked explicitly through `Lock-BitLocker`. Its BitLocker state is described under [Inventory copies](#inventory-copies-on-the-recovery-media).

## What this record does not show

- **That any recovery material restores a cluster.** No restore rehearsal from the off-cluster recovery material has been performed. The incident restoration used a local etcd snapshot and the server token already present on the servers, not the uploaded recovery material. It is therefore not a rehearsal of the design's Track A.
- **The root cause of the incident.**
- **Scheduled backup operation.** The [human access gate](#human-access-gate) has been met, but no backup schedule exists yet.
- **Stage 3 or later work.** Secrets encryption at rest, scheduled etcd uploads, volume backups and machine access keys are not part of Stage 2.
- **Recoverability of anything,** beyond the ciphertext-to-plaintext verifications above. See [Evidence boundaries](../design/backup-disaster-recovery.md#evidence-boundaries-and-claims-not-to-make).
