# Encrypted recovery material validation

## Scope

This record documents the observed results of Stage 2 of the [backup and disaster recovery design](../design/backup-disaster-recovery.md): encrypting the recovery material with `age`, uploading it with the routine role, verifying it, and keeping an inventory of it. The work followed the [encrypted recovery material runbook](../runbooks/encrypted-recovery-material.md).

It also documents a cluster incident that interrupted the work, and the cluster's restoration from a local etcd snapshot.

The Stage 3 `encryption-config` recovery copy and the updated inventory, made on 2026-10-29, are recorded in their [own section](#stage-3-the-k3s-secrets-encryption-configuration-2026-10-29), with their own evidence statement. The interim manual p2 snapshot copy and the inventory update of 2026-10-30 are recorded in [another](#stage-3-the-interim-manual-p2-snapshot-copy-2026-10-30). That copy is not Stage 4.

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
- **Stage 3 or later work.** Secrets encryption at rest, scheduled etcd uploads, volume backups and machine access keys are not part of Stage 2. The Stage 3 recovery copy is recorded [below](#stage-3-the-k3s-secrets-encryption-configuration-2026-10-29).
- **Recoverability of anything,** beyond the ciphertext-to-plaintext verifications above. See [Evidence boundaries](../design/backup-disaster-recovery.md#evidence-boundaries-and-claims-not-to-make).

## Stage 3: the K3s secrets-encryption configuration (2026-10-29)

This section records the [`encryption-config` procedure](../runbooks/encrypted-recovery-material.md#the-k3s-secrets-encryption-configuration-stage-3) run against the live cluster on 2026-10-29 UTC, from 15:30 to 16:50, and the inventory update that followed it.

**How the evidence was produced:**
- The work was run by an operator session, with each step approved by the repository owner. The owner ran the steps that needed the identity-archive passphrase or administrator rights: both `verify` runs, the decryption of the previous inventory, and the recovery-media copies. The owner reported their results.
- Sanitized evidence is stored outside this repository: directory `stage3-encryption-config-recovery-copy-20261029T165000Z`, 38 files, whose `SHA256SUMS` manifest has SHA-256 `c9f0e9c3ee4c967fd7de8b71234ab70d716835cab85c885da61f9a69ce0baffc`. The scanner reported no findings in any of them.
- The same exclusions apply as for Stage 2. In addition, no part of the configuration, no key name, and no plaintext size or hash is recorded.

### Timing and implementation

| Item | Value |
| --- | --- |
| Follows | homelab-k3s's single `rotate-keys` (2026-10-29), its second restart round on all three servers, the enforced `enabled` validation, and p2 `stage3-p2-post-encryption-20261029t144551z-k3s01-1793285175` |
| home-cluster helpers | Reviewed `main` commit `9f46215bd55681ff2a5006e95d9a3869d19bbf17` (pull request #21 merged), installed on `k3s01` from `git archive`; both files matched the commit's blobs |
| homelab-k3s | `main` commit `7fd364ffefe11698dbd6ca1d293f73d6bbe35b45` |
| Routine AWS access | `HomeClusterBackupOperator` only; `check-role` printed `PASS` before every AWS step. The IAM Identity Center session had expired at the first preflight and was renewed by the owner before any AWS step |

### Preflight

| Check | Observed |
| --- | --- |
| Cluster | All nodes Ready; local APIs and etcd ready; three-member full mesh; workloads, Flux and storage healthy; `Enabled`, `reencrypt_finished` and matching hashes on all three servers; p2 the newest Stage 3 snapshot, intact and recorded |
| Source, by metadata only | `600 root:root regular file`, nonempty, not a symbolic link, at exactly the expected path. The credential directory was `700 root:root`, not group- or other-writable, with no symbolic link above it |
| Swap | None active on `k3s01` or in WSL (`swap=0`) |
| `age` | v1.3.2 on `k3s01` and in WSL |
| Bucket configuration, read with the routine role | Versioning `Enabled`; all four Block Public Access settings `true`; policy status not public; default encryption `AES256`; ownership `BucketOwnerEnforced` |
| Destinations | Both `2026-10-29` keys absent before upload; the only previous inventory object was `recovery/recovery-inventory/2026-10-18.age` |
| Identity archive | The passphrase-encrypted archive's ciphertext SHA-256 matched the value recorded above before each use |

### Results

| Item | Object key | Ciphertext | Upload | Exact-version download | Decryption comparison | `cmp -s` exit status |
| --- | --- | --- | --- | --- | --- | --- |
| `encryption-config` | `recovery/encryption-config/2026-10-29.age` | 472 bytes, SHA-256 `12182aec61bcaf1839eb882292617d1fa871ea3d9605116ff382713f8c9f2e6c` | PASS, receipt-based | `MATCH` | `MATCH` against the live source, on `k3s01`, with the recovery tmpfs absent afterwards | 0 |
| `recovery-inventory` | `recovery/recovery-inventory/2026-10-29.age` | 6191 bytes, SHA-256 `c85b47c6a27be89ca7583836f46f6265bb0a6c527c685da110ea0d9a26e4235b` | PASS, receipt-based | `MATCH` | `MATCH` against the prepared inventory, on the workstation | 0 |

All four Stage 3 completion checks passed for the same `encryption-config` object version. Its recovery-copy status is `verified`. This is the first such copy, so nothing is superseded.

### The updated inventory

- **Built only in a private WSL tmpfs**, from the 2026-10-18 inventory, which was decrypted into that tmpfs only.
- **Rows:** the four placeholder rows of the earlier template for the secrets-encryption material were replaced by the ten current `K3s secrets-encryption configuration` rows. The record fields and tool versions were updated. Previous inventory object: `recovery/recovery-inventory/2026-10-18.age`.
- **Checks:** 56 table rows, no placeholders left, and no scanner findings.
- **Version IDs:** both were read from their receipts directly into the inventory and never displayed.
- **Copies:** the exact-version downloaded, byte-matched ciphertext was copied to both recovery devices.

| Copy | Size | SHA-256 | BitLocker state before the copy | Comparison | Afterwards |
| --- | --- | --- | --- | --- | --- |
| Recovery A | 6191 bytes | `c85b47c6…235b` | Unlocked; fully encrypted; protection On; AES-256; automatic unlock disabled | PASS. Create-new, nothing overwritten; the Stage 2 copy is still present | Safely ejected and disconnected |
| Recovery B | 6191 bytes | `c85b47c6…235b` | Same | PASS. Create-new; the Stage 2 copy is still present | Safely ejected and disconnected |

### Cleanup

| Host | Observed |
| --- | --- |
| `k3s01` | The transported identity archive, all `.age` files and the helper copy were removed. No recovery tmpfs. The live source is still present |
| Workstation (WSL) | The inventory plaintext, both receipts and the inventory tmpfs were removed. The run's private working directory and its five ciphertexts were removed. The keep-alive was stopped. Both Stage 2 inventory ciphertexts, which match each other, and the Stage 2 working directories are untouched |

### Deviations and qualifications

- **WSL shut down and took the encryption-config receipt with it.** The WSL virtual machine shut down between steps while no WSL process was running, and the next command started it again at 15:53:36 UTC. That removed the inventory tmpfs and the `encryption-config` receipt; no plaintext was in it. With approval, the receipt was rebuilt from read-only S3 metadata:
  - exactly one version and no delete marker for the exact key, the latest version, 472 bytes;
  - `ChecksumSHA256` equal to the ciphertext SHA-256;
  - written in the helper's format without printing the version ID;
  - proven by an exact-version download that reported `MATCH` against the original ciphertext.

  No second version was uploaded. The [runbook](../runbooks/encrypted-recovery-material.md#prerequisites-and-live-pass-gates) now requires a WSL keep-alive.
- **Decrypting the previous inventory.** The 2026-10-18 inventory was decrypted with `age -d` into the inventory tmpfs, outside the helper, to update it. This was approved.
- **Editing the inventory.** It was edited by a script inside the tmpfs instead of `vim`, printing only row labels and counts. This was approved.
- **Workstation working files.** These were kept in a new private subdirectory, so that the runbook's cleanup could not remove the Stage 2 ciphertexts that share `~/hc-recovery`. This was approved.

### What this section does not show

- **That the copy restores the key onto servers that lost it.** No restore rehearsal from the off-node recovery material was performed.
- **Hypervisor paging.** That host page files or VM swap files did not hold recovery plaintext; see the runbook's [residual risks](../runbooks/encrypted-recovery-material.md#residual-risks).
- **Scheduled operation.** No backup schedule exists yet.

## Stage 3: the interim manual p2 snapshot copy (2026-10-30)

This section records the [interim manual p2 snapshot copy](../runbooks/encrypted-recovery-material.md#the-interim-manual-p2-snapshot-copy-stage3-p2-snapshot) made from the live cluster on 2026-10-30 UTC, and the inventory update that followed it. The run started with the read-only AWS preflight; encryption on `k3s01` began at 12:55 and the final cleanup check ended at 15:27.

**This is an interim manual Stage 3 recovery copy. It is not Stage 4.** It does not configure, test or replace K3s's scheduled snapshot uploads under `etcd/`, which remain pending.

**How the evidence was produced:**
- The work was run by an operator session in gated steps, each approved by the repository owner. The owner ran the steps that needed the identity-archive passphrase or administrator rights: both decryption comparisons, the decryption of the previous inventory, and the recovery-media copies. The owner reported their results.
- Sanitized evidence is stored outside this repository: 11 directories named `stage3-p2-interim-copy-G<step>-<UTC time>`, 38 files. Each directory has a `SHA256SUMS` manifest. The index `stage3-p2-interim-copy-INDEX-20261030.txt` lists the SHA-256 of every manifest, and has SHA-256 `1f2afd7017b235f5622bcf97eb4b1dd68f5b8dcda23a17f2e236cc160f036a49`. Every manifest and the index verified.
- A scan of the evidence for addresses, user and Windows paths, account and bucket details, ARNs, version IDs, drive letters, device labels, serials, identity or key material, snapshot names and unexpected digests reported no findings. Before the manifests were made, two device labels were replaced by device names, a preservation baseline was reduced to one opaque digest per entry, and two files were restricted to mode `600`.
- The same exclusions apply as for Stage 2. In addition, no snapshot plaintext size or hash is recorded.

### Timing and implementation (2026-10-30)

| Item | Value |
| --- | --- |
| Source | The p2 snapshot recorded on `k3s01` on 2026-10-29 (see [Timing and implementation](#timing-and-implementation) above), selected only from the single `p2-post-encryption` record in the Stage 3 checkpoints file; its name was never typed |
| home-cluster helpers | Reviewed `main` commit `39776b6` (pull request #25 merged), installed on `k3s01` from `git archive`; both files matched the commit's blobs |
| homelab-k3s | `main` commit `7bbb8fb` |
| Routine AWS access | `HomeClusterBackupOperator` only; `check-role` printed `PASS` before every AWS step. The session had expired at the start and was renewed by the owner |

### Preflight (2026-10-30)

| Check | Observed |
| --- | --- |
| Bucket configuration, read with the routine role | Versioning `Enabled`; default encryption `AES256`; all four Block Public Access settings `true`; policy status not public; all six lifecycle rules equal to the committed template, none expiring or transitioning current versions under `recovery/`. No `AccessDenied` |
| Destination | `recovery/stage3-p2-snapshot/2026-10-29.age` absent: no versions, no delete markers, `HeadObject` 404. Rechecked immediately before the upload |
| Previous inventory | `recovery/recovery-inventory/2026-10-29.age` had one current version; its stored `ChecksumSHA256` matched the ciphertext SHA-256 recorded above |
| Cluster | `k3s` active on `k3s01`; local `/readyz` and `/readyz/etcd` `ok`; all three nodes Ready. The same before and after the decryption comparison, and before and after the `k3s01` cleanup |
| Source, by metadata only | `600 root:root`, one link, a regular file at a path that resolves to itself, in a `root:root` directory with no group or other write; within 64 MiB. Size, modification time and SHA-256 matched the checkpoint record (compared, never printed) |
| Swap and memory | No swap active on `k3s01` or in WSL; `MemAvailable` above twice the private tmpfs size |

### Results (2026-10-30)

| Item | Object key | Ciphertext | Upload | Exact-version download | Decryption comparison | `cmp -s` exit status |
| --- | --- | --- | --- | --- | --- | --- |
| `stage3-p2-snapshot` | `recovery/stage3-p2-snapshot/2026-10-29.age` | 10152584 bytes, SHA-256 `21126ab8cd52f7c3f34053ecfb5ba2424480190b564c1540dd3ce39a6dda5cf0` | PASS, once, receipt-based; one current version, no delete marker; stored checksum and size matched | `MATCH` | `MATCH` against the checkpoint-bound source, on `k3s01`, in an 80 MiB private tmpfs, absent afterwards | 0 |
| `recovery-inventory` | `recovery/recovery-inventory/2026-10-30.age` | 7728 bytes, SHA-256 `992a4979ad8d32cea6878e6014e071c7327abbf682a2e461881987935dcd6e4a`, encrypted 2026-10-30 14:20:49 UTC | PASS, once, receipt-based; one current version, no delete marker; stored checksum and size matched | `MATCH` | `MATCH` against the prepared inventory, on the workstation, absent afterwards | 0 |

The `stage3-p2-snapshot` ciphertext was encrypted on `k3s01` through `sudo` from the operator's account, as a `600`, operator-owned, singly linked file, and the helper checked the source again after encrypting. It was fetched to the workstation as ciphertext only. The exact-version download was compared byte for byte with the uploaded ciphertext before it was copied back to `k3s01` for the decryption comparison. Its recovery-copy status is `verified`.

### The updated inventory (2026-10-30)

- **Built only in the private WSL tmpfs**, from the 2026-10-29 inventory, which `decrypt-inventory` decrypted into that tmpfs. That plaintext was removed before encryption.
- **Changed:** Inventory date `2026-10-30`; home-cluster rebuild revision `39776b6`; Previous inventory object `recovery/recovery-inventory/2026-10-29.age`; the **Previous inventory ciphertext SHA-256** row, added with its previously recorded value; and the twelve **Interim manual p2 snapshot copy** rows, added. Every other line was unchanged and in order.
- **The p2 rows** hold:
  - the receipt's key and version ID, read inside the tmpfs and never displayed;
  - the ciphertext SHA-256 and size above, and the snapshot name from the checkpoint;
  - both comparisons and the cleanup result;
  - the restore dependencies, naming the inventory's own server-token and encryption-config objects;
  - the scope, "not a Stage 4 K3s upload under `etcd/`", and status `verified`.
- **Checks:** `--check-inventory` with `--previous-key` and `--previous-sha256` printed `PASS`; the scan reported no findings; no placeholders were left; 69 table rows.
- **Copies:** the exact-version downloaded, byte-matched ciphertext was copied create-new to both recovery devices as `recovery-inventory-2026-10-30-20261030T142049Z.age`.

| Copy | Result | Afterwards |
| --- | --- | --- |
| Recovery A | Verified, as reported by the owner. The reviewed copy script refuses unless exactly one recovery device is connected, with BitLocker unlocked, fully encrypted, protection On, AES-256 and automatic unlock disabled; the destination is absent; and the copy has 7728 bytes and the recorded SHA-256, the file count rises by one and every pre-existing file is unchanged | Disconnected, as reported by the owner |
| Recovery B | Verified, as reported by the owner, with the same script | Disconnected, as reported by the owner |

No recovery device was connected at cleanup. The lock result of either device was not observed and is not recorded.

### Cleanup (2026-10-30)

| Host | Observed |
| --- | --- |
| `k3s01` | The helper's scoped cleanup removed exactly the two p2 ciphertexts and the transported identity archive, then the run directory. The helper and recipient copies were removed by name. `~/hc-recovery` absent, no `.age` files in the operator's home, no recovery tmpfs. The p2 snapshot and the checkpoints file were unchanged, and the snapshot still matched its record |
| Workstation (WSL) | The updated inventory plaintext and both receipts were removed by name, and the inventory tmpfs was unmounted and removed. The keep-alive was stopped. The run's scoped cleanup removed exactly its four ciphertexts and the run directory, and retained the previous-inventory ciphertext unchanged. Every other entry under `~/hc-recovery`, including the Stage 2 files, matched its pre-cleanup baseline. No evidence directory was removed |
| S3 | Nothing deleted. The p2 object, the 2026-10-30 inventory and the 2026-10-29 inventory each still had one current version and no delete marker |

### Deviations and qualifications (2026-10-30)

All were approved by the owner.
- **Previous inventory ciphertext.** No copy from the 2026-10-29 run was left on the workstation, and the offline copies were out of scope. The current version of the 2026-10-29 inventory was therefore retrieved from S3 by a pinned `get-object`, because the S3 helper's `download` needs `--compare-with`. Its SHA-256 matched both the stored checksum and the recorded value. It is kept outside the inventory tmpfs and the run directory, in `~/hc-recovery/prior-inventory-2026-10-29/`.
- **Inventory date.** `2026-10-30`, the run's date, so the inventory went to a new key rather than to a same-date new version.
- **Rebuild revision.** Set to `39776b6`, the first `main` revision with the `stage3-p2-snapshot` item.
- **Editing the inventory.** By a reviewed script inside the tmpfs instead of `vim`, printing only checks and counts.
- **Transport to and from `k3s01`.** The workstation has no `k3s01` SSH alias, so the helper archive, the ciphertext fetch and the copies to `k3s01` went through the reviewed Ansible inventory:
  - the `git archive` output was embedded in an Ansible `script`;
  - the fetch was flat and of the ciphertext only;
  - the copies used `force=no` and were checked to be new.

  The owner's interactive decryption comparison used `ssh -t` with the same inventory settings.
- **Stops caused by driver defects.** Each stopped a step before anything changed in AWS and before any file was transferred twice; each upload ran exactly once:
  - a credential check that counted the hygiene variable `AWS_PAGER`;
  - an AWS wrapper that passed its own label to the CLI;
  - a keep-alive started by the operator session that exited early, after which the owner ran it in their own window;
  - two output-masking and ordering errors in the checks around the `k3s01` transfer.
- **Terminal exposure.** The server address appeared once in the owner's terminal, in SSH's closing message, and a user-home path appeared once in the operator session's output. Neither is in the evidence.

### What this section does not show

- **A restore.** No restore rehearsal from this copy, or from any off-node recovery material, was performed. Whether the p2 copy, the server token and the encryption configuration together restore the cluster onto servers that lost all three is untested.
- **Stage 4.** No K3s `etcd-s3` setting was added, nothing was written under `etcd/`, and the etcd machine identity was not used. K3s's scheduled uploads, naming, pruning and retention are untested.
- **Later cluster state.** The copy holds the cluster as it was at p2 on 2026-10-29.
- **The recovery devices directly.** Their results are as reported by the owner; the operator session did not observe the copy output or a lock result.
- **Hypervisor paging.** As for Stage 2; see the runbook's [residual risks](../runbooks/encrypted-recovery-material.md#residual-risks).
