# Recovery-material inventory: blank template

This is the blank template for the recovery-material inventory described in the [backup and disaster recovery design](../design/backup-disaster-recovery.md#recovery-material-inventory). It is filled in during the [encrypted recovery material runbook](encrypted-recovery-material.md).

**A filled copy is never committed.** It records backup identifiers and version IDs. Its plaintext exists only in two places:
- a private, memory-backed tmpfs on the workstation, with swap disabled, while it is prepared;
- the BitLocker recovery media, when an offline plaintext copy is required.

It is never created on the WSL virtual disk, the Windows system disk, OneDrive or in the repository. The runbook's [filled inventory](encrypted-recovery-material.md#the-filled-inventory) section gives the exact steps:
- create and verify the tmpfs;
- fill in the copy as `recovery-material-inventory.md`, a name `.gitignore` excludes;
- encrypt, upload and verify it;
- copy the ciphertext to Recovery A and then Recovery B;
- remove the tmpfs.

**The inventory points to secrets; it never holds them.** Never write any of these into a filled copy:

- a secret value, or any hash, fingerprint, prefix or length of one;
- any part of the K3s secrets-encryption configuration: a key, a key name, a provider entry, or a hash or size of the plaintext file;
- the private identity, the identity-archive passphrase, or a passphrase hint;
- the off-site location, the holder of Recovery B, or device serial numbers;
- an AWS account ID, ARN, IAM Identity Center identifier, portal URL or email address;
- the size or SHA-256 of the p2 snapshot itself. The interim manual p2 snapshot copy rows record its ciphertext only.

Every value below is a placeholder. The repository check (`scripts/validate-recovery-material.py`) fails if:
- a value cell in this template is anything else;
- a required row is missing;
- a field asks for a plaintext-derived value or key material.

The **Previous inventory ciphertext SHA-256** row and the **Interim manual p2 snapshot copy** rows were added after the 2026-10-29 inventory. A previous inventory may lack them, but every replacement inventory must have them.

## Record

| Field | Value |
| --- | --- |
| Inventory date | `<YYYY-MM-DD>` |
| Prepared by | `<role, not a personal email address>` |
| home-cluster revision to rebuild from | `<commit SHA>` |
| homelab-k3s revision to rebuild from | `<commit SHA>` |
| Previous inventory object | `<recovery/recovery-inventory/YYYY-MM-DD.age, or none>` |
| Previous inventory ciphertext SHA-256 | `<ciphertext SHA-256 of the inventory version being replaced, or none>` |

## Recovery objects

| Item | Field | Value |
| --- | --- | --- |
| K3s server token | Object key | `<recovery/k3s-server-token/YYYY-MM-DD.age>` |
| K3s server token | S3 version ID | `<version ID>` |
| K3s server token | Ciphertext SHA-256 | `<ciphertext SHA-256>` |
| K3s server token | Last verification | `<YYYY-MM-DD, cmp -s result>` |
| K3s secrets-encryption configuration | Object key | `<recovery/encryption-config/YYYY-MM-DD.age>` |
| K3s secrets-encryption configuration | S3 version ID | `<version ID, from the private upload receipt>` |
| K3s secrets-encryption configuration | Ciphertext SHA-256 | `<ciphertext SHA-256>` |
| K3s secrets-encryption configuration | Ciphertext bytes | `<ciphertext size in bytes>` |
| K3s secrets-encryption configuration | Source check | `<PASS: expected path, regular file, nonempty, root:root, no group or other access, directory root:root and not group or other writable>` |
| K3s secrets-encryption configuration | Exact-version download comparison | `<YYYY-MM-DD, MATCH or DIFFER>` |
| K3s secrets-encryption configuration | Decryption comparison | `<YYYY-MM-DD, MATCH, DIFFER or ERROR>` |
| K3s secrets-encryption configuration | Verification cleanup | `<YYYY-MM-DD, tmpfs files removed and tmpfs unmounted: yes or no>` |
| K3s secrets-encryption configuration | Key state it follows | `<UTC date of the rotate-keys run and p2 snapshot name it follows>` |
| K3s secrets-encryption configuration | Recovery-copy status | `<verified, unverified, or superseded by YYYY-MM-DD>` |
| Interim manual p2 snapshot copy | Object key | `<recovery/stage3-p2-snapshot/YYYY-MM-DD.age, or not made>` |
| Interim manual p2 snapshot copy | S3 version ID | `<version ID, from the private upload receipt>` |
| Interim manual p2 snapshot copy | Ciphertext SHA-256 | `<ciphertext SHA-256>` |
| Interim manual p2 snapshot copy | Ciphertext bytes | `<ciphertext size in bytes>` |
| Interim manual p2 snapshot copy | Snapshot it preserves | `<snapshot file name, checkpoint label p2-post-encryption>` |
| Interim manual p2 snapshot copy | Source check | `<PASS: snapshot directory, p2 name, regular file, root:root, mode 600, single link, within 64 MiB, the only p2 checkpoint record matching>` |
| Interim manual p2 snapshot copy | Exact-version download comparison | `<YYYY-MM-DD, MATCH or DIFFER>` |
| Interim manual p2 snapshot copy | Decryption comparison | `<YYYY-MM-DD, MATCH, DIFFER or ERROR>` |
| Interim manual p2 snapshot copy | Verification cleanup | `<YYYY-MM-DD, tmpfs files removed and tmpfs unmounted: yes or no>` |
| Interim manual p2 snapshot copy | Restore dependencies | `<the server token object and the encryption-config object it needs>` |
| Interim manual p2 snapshot copy | Scope | `<interim manual copy under recovery/; not a Stage 4 K3s upload under etcd/>` |
| Interim manual p2 snapshot copy | Recovery-copy status | `<verified, unverified, or superseded by a Stage 4 etcd/ upload on YYYY-MM-DD>` |
| Grafana admin credential | Object key | `<recovery/grafana-admin/YYYY-MM-DD.age>` |
| Grafana admin credential | S3 version ID | `<version ID>` |
| Grafana admin credential | Ciphertext SHA-256 | `<ciphertext SHA-256>` |
| Grafana admin credential | Last verification | `<YYYY-MM-DD, cmp -s result>` |
| Grafana admin credential | Secret it recreates | `<namespace/name>` |
| Velero repository password | Object key | `<object key, or not yet created (Stage 5)>` |
| Velero repository password | S3 version ID | `<version ID, or not applicable>` |
| Velero repository password | Last verification | `<YYYY-MM-DD, cmp -s result, or not applicable>` |
| Velero repository password | Secret it recreates | `<namespace/name, or not applicable>` |

## Storage map

| Field | Value |
| --- | --- |
| Bucket | `<backup bucket name>` |
| Region | `<region>` |
| Prefixes | `<etcd/, volumes/, recovery/, evidence/>` |

## Selected restore points

| Field | Value |
| --- | --- |
| etcd snapshot names and S3 version IDs | `<names and version IDs of Stage 4 K3s uploads under etcd/, or none yet (Stage 4); never the interim manual p2 copy>` |
| Velero backup names | `<names, or none yet (Stage 5)>` |

## Tool versions

| Tool | Value |
| --- | --- |
| K3s | `<version>` |
| age | `<version>` |
| AWS CLI | `<version>` |
| Velero | `<version, or not installed>` |
| Velero AWS plugin | `<version, or not installed>` |
| Kopia (as bundled with Velero) | `<version, or not installed>` |

## The age identity

| Copy | Field | Value |
| --- | --- | --- |
| Recovery A | Protection method | `<method>` |
| Recovery A | Last unlock and decryption test | `<YYYY-MM-DD, result>` |
| Recovery B | Protection method | `<method; never the location or holder>` |
| Recovery B | Last unlock and decryption test | `<YYYY-MM-DD, result>` |
| Online passphrase-encrypted copy | Archive ciphertext SHA-256 | `<ciphertext SHA-256>` |
| Online passphrase-encrypted copy | Last decryption and byte-comparison test | `<YYYY-MM-DD, result>` |
| All copies | Unlock procedure | `<pointer to the runbook section; never the passphrase or a hint>` |

## Access and dependencies

| Field | Value |
| --- | --- |
| Routine access path | `<IAM Identity Center permission-set name only>` |
| External rebuild dependencies | `<pointer to the Stage 0 dependency inventory>` |
| Next quarterly review | `<YYYY-MM-DD>` |
