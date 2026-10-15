# Design: off-cluster backup and disaster recovery

**Status:** Stage 0 preflight is complete. Stage 1, the AWS foundation, was deployed on 2026-10-15 and verified, as recorded in the [AWS backup foundation validation](../validation/aws-backup-foundation.md): the versioned backup bucket, the two machine IAM users and the `HomeClusterBackupOperator` permission set exist. No machine access keys exist, no backup data or recovery material has been uploaded, no cluster configuration has changed, no off-cluster backup schedule or backup software has been configured, and no restore has been rehearsed. Each implementation stage below is a separate, reviewed PR (or a recorded manual action where noted), gated by its own evidence.

This design follows the safety model of the [Flux reconciliation-split design](flux-reconciliation-split.md) and the [observability design](observability.md): evidence first, one concern per PR, static validation and a disposable rehearsal before merge, explicit stop conditions and rollback, and documentation limited to what was observed.

**Backups are not recoverability.** In this design, a successful upload, a matching checksum or an object listing shows only that bytes exist off-cluster. Recoverability is claimed only for what an isolated restore rehearsal has actually restored. Complete disaster recovery is not claimed until both etcd and persistent-volume restoration have been rehearsed, as described under [Evidence boundaries](#evidence-boundaries-and-claims-not-to-make).

## Decisions

| Topic | Decision |
| --- | --- |
| Off-cluster target | One private, versioned S3 bucket in `us-east-1`, in the member account. Separate prefixes for etcd, volume backups, recovery material and evidence. |
| Bucket encryption | Default **SSE-S3** (`AES256`). No customer-managed KMS key initially; see [Encryption](#encryption-sse-s3-first). |
| Machine identities | Two dedicated IAM users, one for K3s etcd uploads and one for Velero, each limited to its own prefix. Static access keys, because the cluster is not EKS; see [Why static access keys](#why-static-access-keys). No personal SSO credentials, `AdministratorAccess` or root credentials are used by any automated process. |
| etcd | Keep the existing K3s schedule (twice daily, five local snapshots per node) and add K3s's built-in S3 upload. Each snapshot is restorable only with the matching server token. |
| Secret encryption at rest | **A separate prerequisite stage**, completed before any etcd snapshot leaves the cluster; see [Secrets encryption at rest](#secrets-encryption-at-rest-prerequisite-stage). |
| Persistent volumes | Velero file-system backup with the Kopia uploader for the Prometheus and Grafana claims, **conditional on the rehearsal proving that it can read `local-path` volumes**. |
| Recovery material | The K3s server token, the Grafana admin credential, the Velero repository password and (after the prerequisite stage) the K3s encryption configuration. Each is encrypted client-side with `age` to an offline-held key before upload, and is uploaded by a human administrator, never by a machine identity. |
| AWS provisioning | CloudFormation in this repository outside `clusters/`, deployed by a human administrator through an IAM Identity Center session. Access keys are never created by the template. **Approved for Stage 1.** |
| Stage order | Adds the secrets-encryption prerequisite and moves recovery material ahead of the etcd uploads. **Approved.** |

## Goals

1. Keep a copy of everything needed to rebuild the cluster's state outside the cluster's hardware: etcd snapshots, the matching server token, persistent-volume data, and the out-of-band credentials that are not in Git.
2. Make every copy restorable, and prove it by isolated restore rehearsal before claiming it.
3. Keep every secret out of Git, logs and evidence. Material that would expose a secret is encrypted on the source host before it leaves it.
4. Give machine identities only what they need: write to their own prefix, and no ability to destroy object history or change bucket protections.
5. Stay below the existing $10 monthly organization budget under expected use, with margin for a restore rehearsal.
6. State explicit recovery objectives, and measure them in the rehearsal rather than assuming them.

## Non-goals

- **Backing up what Git already holds.** Flux manifests are restored from GitHub, not from backups. Git hosting availability is outside this design.
- **Multi-region or cross-account copies.** A `us-east-1` outage, or loss or compromise of the member account, is not covered; see [Evidence boundaries](#evidence-boundaries-and-claims-not-to-make).
- **Immutable (WORM) backups.** S3 Object Lock is deferred; see [Deletion protection](#deletion-protection).
- **High availability or replicated storage** for Prometheus and Grafana. Replacing `local-path` belongs to the separate persistent-storage design listed in the README.
- **VM and operating-system backup.** Nodes are rebuilt from [homelab-k3s](https://github.com/triley76/homelab-k3s), not restored from images.
- **Application-consistent database backups.** Volume copies are file-level and crash-consistent at best; see [Persistent-volume backup](#persistent-volume-backup-velero-with-kopia).
- **Automated failover** to a standby cluster.

## Current state (recorded facts)

These facts were supplied by the repository owner for this design. They are re-verified in [Stage 0](#stage-0-preflight-read-only).

| Item | Recorded state |
| --- | --- |
| Cluster | Three K3s `v1.36.4+k3s1` server nodes with embedded etcd |
| etcd snapshots | Scheduled local snapshots twice daily, five retained per node, healthy, stored only on the nodes |
| K3s server token | Present on the servers, mode `0600`. Required for restore. Its value and any fingerprint of it are never committed or recorded |
| Secret encryption at rest | Disabled. Kubernetes Secrets are stored in etcd, and therefore in every snapshot, without encryption |
| Declarative state | GitHub and Flux are the source of truth for manifests |
| Prometheus storage | 10 GiB `local-path` claim on `k3s02`, about 3.9 GiB used |
| Grafana storage | 1 GiB `local-path` claim on `k3s01`, about 2.4 MiB used |
| Grafana admin credential | Created out of band (`monitoring/grafana-admin` and a protected file outside the repository); never committed |
| AWS account | A member account in an AWS Organization; region `us-east-1`. The account ID is not recorded in Git |
| Human administration | IAM Identity Center with MFA; temporary `AdministratorAccess` sessions |
| S3 | No buckets exist in the member account. The AWS-managed key `alias/aws/s3` is available |
| Cost control | An organization-wide $10 monthly AWS Budget in the management account, with three alerts and a verified recipient |

Consequences that shape this design:

- **An etcd snapshot is currently a plaintext copy of every Secret in the cluster.** That includes the Grafana admin Secret, Helm release Secrets and any service-account token Secrets. Uploading snapshots before secrets encryption is enabled would place those values in S3, protected only by server-side encryption that any principal with `s3:GetObject` decrypts transparently.
- **K3s stores its bootstrap data in etcd encrypted with a key derived from the server token.** That data includes the cluster certificates and keys. A snapshot restored without the matching token is not usable. Off-cluster snapshots without a recoverable token are not backups.
- **Both claims are node-local.** Losing `k3s02` or `k3s01` loses that volume's data, even though etcd keeps quorum with two nodes.

## Failure scenarios and coverage

| Scenario | Covered by | Notes |
| --- | --- | --- |
| One node lost, etcd keeps quorum | Existing HA; volume restore if the lost node held a claim | No etcd restore is needed |
| Accidental deletion of cluster objects | Git and Flux for declarative objects; etcd snapshot for out-of-band objects | A whole-cluster etcd restore is a large hammer for one object; this is noted, not solved |
| Prometheus or Grafana volume lost or corrupted | Velero volume backup | Daily recovery point |
| All three nodes lost (site or hypervisor loss) | Rebuild with homelab-k3s, then etcd restore from S3 with the recovered token, then volume restores | The full disaster-recovery path |
| Cluster credentials leaked | Rotation and revocation procedures | Machine identities cannot delete object versions |
| Backup credential misused | Versioning, bucket-policy denies, noncurrent-version retention | Not protection against the account administrator or root |
| Loss of the offline `age` key | Not recoverable from backups | Recovery material must be re-created from live sources while they still exist |
| `us-east-1` or AWS account unavailable | Not covered | Local node snapshots remain the only copy |

## External dependencies for a full rebuild

Backups cover cluster state, volumes and recovery material. A complete rebuild also depends on things this design does not back up:

| Dependency | Why it matters |
| --- | --- |
| GitHub availability, and access to both `home-cluster` and `homelab-k3s` | Flux manifests and node provisioning come from them |
| homelab-k3s being sufficient to recreate the nodes | Images, VMs, operating-system configuration, K3s installation and kube-vip must be reproducible from it alone |
| VMware, network and DNS configuration | Port groups, VLANs, addressing, DHCP exclusions, router settings and DNS records are not necessarily stored in either repository |
| Access to AWS and to the offline `age` identity | Without both, no off-cluster backup or recovery material can be read |
| Compatible versions of K3s, Velero, Kopia (as bundled with Velero) and the Velero AWS plugin | A snapshot or repository may not restore with a different version. The versions in use are recorded in the [recovery-material inventory](#recovery-material-inventory) |

**Any VMware, network or DNS configuration that is not recorded somewhere recoverable is a recovery gap.** Stage 0 inventories these, and records each item's location, or the gap, outside the cluster.

## Proposed architecture

```text
            K3s servers (k3s01..03)                       Cluster workloads
  ┌───────────────────────────────────────┐   ┌──────────────────────────────────┐
  │ scheduled etcd snapshot (local, 5/node)│   │ Velero server + node-agent       │
  │   └─ K3s built-in S3 upload ───────────┼─┐ │   Kopia repo (client-side enc.)  │
  │      identity: etcd uploader           │ │ │   identity: Velero               │
  └───────────────────────────────────────┘ │ └───────────────┬──────────────────┘
                                             │                 │
   Administrator workstation (SSO + MFA)     │                 │
   age-encrypted recovery material ──────┐   │                 │
   rehearsal evidence archives ──────────┤   │                 │
                                         ▼   ▼                 ▼
                    s3://<backup-bucket>/  (us-east-1, private, versioned, SSE-S3)
                    ├── recovery/   human upload only; age ciphertext
                    ├── evidence/   human upload only; credential-scanned archives
                    ├── etcd/       K3s snapshots and K3s snapshot metadata
                    └── volumes/    Velero backup metadata and Kopia repository
```

Placement by repository:

- **AWS resources**: CloudFormation under `aws/backup/`, outside `clusters/`, reviewed in a PR and deployed by a human.
- **K3s server configuration** (secrets encryption, etcd S3 upload): server configuration is provisioned by [homelab-k3s](https://github.com/triley76/homelab-k3s), so those changes are PRs there. This repository records the design and the evidence.
- **Velero**: Flux-managed in this repository, as a new `backup` layer:

```text
clusters/home/
├── backup.yaml                 # Flux Kustomizations: backup (depends on infrastructure-configs), backup-configs
└── backup/
    ├── controllers/            # velero Namespace (privileged), HelmRepository, HelmRelease
    └── configs/                # BackupStorageLocation, Schedules
```

`backup` depends on `infrastructure-configs` and is independent of `apps` and `monitoring`, following the monitoring pattern. `backup-configs` depends on `backup`, because the Velero custom resources need its CRDs.

## S3 bucket design

### Settings

| Setting | Value |
| --- | --- |
| Name | `home-cluster-backup-<random-suffix>`. Bucket names are global; the name never contains the account ID. Account-regional names that embed the account ID are not used |
| Region | `us-east-1` |
| Block Public Access | All four settings on, at the bucket. The account-level setting is checked in preflight and also enabled if it is off |
| Object Ownership | Bucket owner enforced (ACLs disabled) |
| Versioning | Enabled before any object is written |
| Default encryption | SSE-S3 (`AES256`) |
| Bucket policy | See [Bucket policy](#bucket-policy) |
| Lifecycle | See [Lifecycle and retention](#lifecycle-and-retention) |
| Storage class | S3 Standard for everything. Infrequent-access and archive classes are not used: the data is small, Kopia rewrites and reads its blobs during maintenance, and those classes add minimum-duration, minimum-size and retrieval charges |
| Access logging | None initially; see [Open decisions](#open-decisions) |
| Tags | `project=home-cluster`, `purpose=backup`, for cost allocation |

### Encryption: SSE-S3 first

The bucket uses **SSE-S3** (`AES256`, S3-managed keys).

**`alias/aws/s3` is not part of SSE-S3.** It is the AWS-managed KMS key that S3 uses for SSE-KMS when no customer key is named. Choosing it would mean SSE-KMS: KMS request charges (reduced by S3 Bucket Keys), key usage visible in CloudTrail, and no extra access control, because an AWS-managed key's policy cannot be edited. The design therefore does not use it. It is noted here because the recorded facts list it as available.

Why SSE-S3 rather than a customer-managed KMS key initially:

- **Cost.** A customer-managed key costs $1 per month, before request charges, plus additional charges for rotated key material at current published pricing. That alone is 10% of the $10 budget. SSE-S3 has no key or request charges.
- **The threat it would address is handled elsewhere.** A customer-managed key's main benefit is a second, independent authorization: reading an object needs both S3 and KMS permissions. Here the sensitive material does not rely on server-side encryption:
  - Velero volume data is encrypted client-side by Kopia;
  - recovery material is encrypted client-side with `age`;
  - etcd snapshots are uploaded only after Kubernetes Secret encryption is enabled.
- **Simplicity.** No key policy to lock oneself out with, and no extra KMS permissions for the machine identities.

What SSE-S3 does **not** provide: protection against anyone who holds `s3:GetObject` on the object. S3 decrypts transparently for them.

**Future migration option.** If a later requirement needs a customer-managed key (for example, separate decryption authority or key-usage auditing):

1. create the key with a key policy that grants the two machine identities `kms:GenerateDataKey` and `kms:Decrypt` only;
2. switch the bucket's default encryption to SSE-KMS with that key and enable S3 Bucket Keys;
3. existing objects keep SSE-S3 until they are rewritten or expire. Lifecycle turnover replaces etcd and Kopia objects within a few weeks. Recovery objects are re-uploaded deliberately;
4. update the identity policies and rehearse a restore before relying on the change.

### Bucket policy

The bucket policy denies; it does not grant. Grants come from the identity policies.

| Statement | Effect and scope |
| --- | --- |
| `DenyInsecureTransport` | Deny `s3:*` for all principals when `aws:SecureTransport` is `false` |
| `DenyOldTls` | Deny `s3:*` for all principals when `s3:TlsVersion` is below `1.2` |
| `DenySseC` | Deny `s3:PutObject` for all principals when a customer-provided encryption key header (`s3:x-amz-server-side-encryption-customer-algorithm`) is present, so stolen credentials cannot re-encrypt objects with a key the owner does not hold |
| `DenyBucketDeletion` | Deny `s3:DeleteBucket` for all principals. Removing this statement is the first, deliberate step of [Teardown](#teardown) |
| `DenyMachineDestructive` | For both machine principals: deny `s3:DeleteObjectVersion`, `s3:PutBucketVersioning`, `s3:PutLifecycleConfiguration`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:PutEncryptionConfiguration`, `s3:PutBucketPublicAccessBlock`, `s3:PutBucketOwnershipControls`, `s3:PutBucketObjectLockConfiguration` and `s3:BypassGovernanceRetention` |
| `DenyMachineOutsidePrefix` | Deny object actions for the etcd principal outside `etcd/*`, and for the Velero principal outside `volumes/*`. Neither can read `recovery/` or `evidence/` |

The template refers to the machine principals with intrinsic functions and the `AWS::AccountId` pseudo-parameter. No account ID is written in the template or anywhere else in Git. Each policy is checked with IAM Access Analyzer policy validation before deployment.

### Lifecycle and retention

| Rule | Scope | Action |
| --- | --- | --- |
| Abort incomplete uploads | Whole bucket | Abort incomplete multipart uploads after 1 day |
| Remove expired delete markers | Whole bucket | Remove delete markers that have no noncurrent versions left |
| etcd history | `etcd/` | Expire noncurrent versions 14 days after they become noncurrent. **Current versions never expire by lifecycle**; K3s is expected to prune them (a rehearsal assertion) |
| Volume history | `volumes/` | Expire noncurrent versions after 7 days. **Current versions never expire by lifecycle**; Velero and Kopia manage them |
| Recovery history | `recovery/` | Expire noncurrent versions after 90 days. Current versions never expire |
| Evidence | `evidence/` | Expire current versions after 365 days; noncurrent versions after 30 days |

Two rules are deliberate:

- **No current-version expiration on `etcd/` or `volumes/`.** If uploads stop, an age-based expiration would eventually delete the last good backups. Freshness is detected by monitoring instead.
- **Lifecycle never touches current Kopia objects.** Expiring live repository blobs would corrupt the repository. Kopia deletes unreferenced blobs itself during maintenance; versioning keeps them for 7 more days.

How versioning is intended to extend retention: when K3s prunes a snapshot, the deletion should create a delete marker, and the snapshot should remain as a noncurrent version for 14 days. Restoring one needs an administrator to copy that version back. The pruning pattern, the delete-marker behavior and noncurrent-version restore are [rehearsal assertions](#etcd-and-k3s-server-token-backup), not established behavior.

### Deletion protection

**These controls are defense in depth, not immutable deletion protection.** They have different strengths against different principals:

- **Against the machine keys:** versioning plus `DenyMachineDestructive`. A leaked machine credential can create delete markers and overwrite objects, but cannot remove history or change the bucket's protections. History survives for the noncurrent windows above.
- **Against administrative mistakes: deliberate friction, not prevention.**
  - `DenyBucketDeletion` applies to every principal until teardown deliberately removes it.
  - The CloudFormation stack has termination protection, and the bucket resource has `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`.

  Each adds a separate, explicit step before data can be destroyed.
- **Against an AWS administrator or root-equivalent authority: no protection.** Such a principal can remove the policy statements, termination protection, versioning and lifecycle rules, and then delete every object version and the bucket. A compromised administrator session, or a compromised root user, can destroy all backups.
- **Not used initially:**
  - **S3 Object Lock.** It is the deferred control that would materially strengthen resistance to administrator compromise, because locked object versions cannot be deleted before their retention expires. Compliance mode would block teardown until retention expires; governance mode adds per-object retention that the Kopia repository must be configured for. It is reconsidered after the first rehearsal.
  - **MFA Delete.** It can be enabled and used only through the root user's API credentials, which conflicts with not using root.

## Machine identities

### Why static access keys

The cluster runs on premises, not on EKS, so there is no IAM Roles for Service Accounts, EKS Pod Identity or instance profile to supply short-lived credentials. The options are:

| Option | Assessment |
| --- | --- |
| Personal IAM Identity Center session | **Rejected.** Sessions expire within hours, so scheduled backups would fail silently; it ties automation to a person; it would put an administrator's credentials on cluster nodes |
| IAM Roles Anywhere | Short-lived credentials from X.509 certificates. It needs a certificate authority, certificate issuance and rotation, and a credential helper on each node and in Velero's pods. K3s's built-in S3 upload expects an access key pair. **Deferred** as a future improvement |
| **Dedicated IAM users with static access keys** | **Chosen.** Supported directly by K3s and Velero. The risks are managed by least privilege, prefix isolation, bucket-policy denies, rotation and monitoring |

### Identities

| Identity | Used by | Grants (identity policy) |
| --- | --- | --- |
| `home-cluster-etcd-backup` | K3s on all three servers | `s3:ListBucket` on the bucket with `s3:prefix` limited to `etcd/*`; `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` on `etcd/*` |
| `home-cluster-velero` | Velero server and node-agent | `s3:ListBucket` with `s3:prefix` limited to `volumes/*`; `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` on `volumes/*` |

Neither identity has console access, any other AWS permission, or access to `recovery/` or `evidence/`. `s3:DeleteObject` is needed because K3s and Velero prune their own backups; under versioning it only creates delete markers.

The etcd identity policy, with placeholders:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListEtcdPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<backup-bucket>",
      "Condition": { "StringLike": { "s3:prefix": ["etcd/*"] } }
    },
    {
      "Sid": "ReadWriteEtcdObjects",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::<backup-bucket>/etcd/*"
    }
  ]
}
```

The exact action set is confirmed during Stage 4 and Stage 5 preflight from `AccessDenied` errors, not widened by guesswork. If K3s or Velero makes a bucket-level call without a prefix (for example, a bucket-existence check), the condition is relaxed to `StringLikeIfExists`. That also allows an unprefixed listing of object names. Object names are designed to contain no secrets. Any widening beyond that is a design amendment.

One shared etcd identity is used for all three servers. Per-node identities would give per-node attribution, but triple the rotation work for the same permissions; see [Open decisions](#open-decisions).

### Storage of credentials

| Credential | Stored | Never stored |
| --- | --- | --- |
| etcd access key | On each server in a K3s configuration drop-in, `/etc/rancher/k3s/config.yaml.d/`, owned by root, mode `0600`, written by homelab-k3s from encrypted Ansible variables | Command-line flags (visible in the process list), systemd unit files, Git, logs, evidence |
| Velero access key | Kubernetes Secret in the `velero` namespace, created out of band like `monitoring/grafana-admin` | Git, Velero backups (Secrets are excluded), logs, evidence |
| Velero repository password | Kubernetes Secret `velero/velero-repo-credentials`, created out of band **before the first backup** (otherwise Velero uses a publicly known default); an `age` copy in `recovery/` | Git, logs, evidence |

Access keys are not part of the recovery material. After a disaster, the administrator issues new keys rather than recovering old ones.

The Velero Secret, and the K3s configuration if it is stored in etcd in the installed version, are inside every etcd snapshot. That is acceptable only once Kubernetes Secret encryption is enabled, which is one reason it is a prerequisite. Stage 4 preflight confirms that the etcd access key does not appear in the `ETCDSnapshotFile` objects or the `k3s-etcd-snapshots` ConfigMap.

Handling rules when a key is created:

- The administrator creates the key in an SSO session. The CLI output is redirected straight into a `0600` file in tmpfs, never to the terminal, a log or persistent disk.
- The key is passed to its destination from that file. The file is then removed and the tmpfs torn down.
- Shell tracing is off, and the AWS CLI's `--debug` is never used during credential handling.

### Rotation

Every 90 days, and immediately after suspected exposure. An IAM user can hold two keys, so rotation has no outage:

1. Create a second key, using the handling rules above.
2. Deploy it: for etcd, the homelab-k3s change plus a rolling K3s restart, one server at a time; for Velero, replace the Secret and restart the Velero pods.
3. Verify a successful upload with the new key: an on-demand etcd snapshot, and an on-demand Velero backup.
4. Deactivate the old key and watch one full schedule cycle.
5. Delete the old key.

Key age is checked monthly from the IAM credential report in an SSO session, and recorded without key identifiers.

### Revocation

In order of speed:

1. Deactivate the access key. This is immediate and reversible.
2. If the identity itself is suspect, attach an explicit deny-all inline policy to the user.
3. Delete the key and create a replacement through the rotation procedure.
4. Follow the leaked-secret procedure in [SECURITY.md](../../SECURITY.md).

Revoking a machine key stops off-cluster backups for that path. Local etcd snapshots continue.

### Credential expiration behavior

- **Static keys do not expire on their own.** Rotation is a procedure, not an automatic control. A recommended backstop, pending approval: an `aws:CurrentTime` condition in each identity policy that ends its grants 120 days after the last rotation, advanced as part of each rotation. A forgotten rotation then fails closed and is caught by the freshness alerts.
- **SSO sessions expire** (hours). That is why they are used only for interactive administration. If a session expires during a manual upload, the upload fails and is retried after signing in again. Nothing scheduled depends on a session.
- **What fails when a machine key stops working:**
  - K3s keeps taking local snapshots, logs the upload failure, and records it on the snapshot's `ETCDSnapshotFile` status and in Kubernetes events;
  - Velero marks backups `Failed` and the storage location `Unavailable`;
  - no local data is affected;
  - the [freshness alerts](#monitoring-and-alerting) fire after one missed cycle.

### Human access

Routine backup operations do not depend on `AdministratorAccess`.

| Access | Used for | When |
| --- | --- | --- |
| Existing `AdministratorAccess` SSO session | Provisioning and break-glass only: deploying and changing the Stage 1 stack; creating, rotating and revoking machine access keys; teardown; and emergencies where the routine identity is insufficient | Stage 1 may be deployed with it initially |
| **Dedicated least-privilege IAM Identity Center permission set** for backup operations | Routine work: recovery-material uploads and verification under `recovery/`; evidence uploads under `evidence/`; inventory and freshness checks (listing objects and versions, reading bucket configuration, the IAM credential report); and restore rehearsals (downloading objects and selected versions, and creating and deleting the rehearsal-only read-only identity) | Created or approved in Stage 1, and in use **before scheduled operation is considered complete** |

The routine permission set is defined in the Stage 1 PR. It contains no bucket-policy, versioning, lifecycle, encryption or bucket-deletion permissions, and it is scoped to the backup bucket. Letting it create and delete the rehearsal identity needs IAM permissions scoped to that one identity. If that cannot be scoped safely, managing rehearsal identities remains an administrator task, and this table is amended.

Permission-set names may appear in Git. Account IDs, portal identifiers and personal email addresses do not.

## etcd and K3s server token backup

**Mechanism.** K3s's built-in S3 support uploads each scheduled snapshot after it is written locally. Configuration, in a drop-in managed by homelab-k3s:

| Setting | Value |
| --- | --- |
| Snapshot schedule | Unchanged: `0 */12 * * *` (the existing twice-daily schedule) |
| Local retention | Unchanged: 5 per node |
| S3 upload | Enabled; bucket `<backup-bucket>`, region `us-east-1`, folder `etcd` |
| Credentials | The etcd identity, from the `0600` drop-in |
| Compression | Recommended: enable snapshot compression, which also changes the local snapshots; the restore rehearsal must use a compressed snapshot. See [Open decisions](#open-decisions) |

The intended outcome is that every server uploads its own snapshots, so the bucket holds three copies of each point in time and uploads continue while any one server is down. K3s is expected to prune S3 snapshots to the configured retention.

**How K3s names, prunes and retains snapshots in S3 is not established fact in this design.** These are rehearsal assertions: each is tested in the Stage 4 k3d/MinIO rehearsal and confirmed against S3 after the Stage 4 live change. The observed behavior is recorded, and this design's retention, lifecycle and cost figures are amended if they differ.

| Assertion | What is recorded |
| --- | --- |
| The installed version supports the options | `k3s server --help` on `v1.36.4+k3s1` lists the S3 and compression options used |
| Object naming from three servers | Object keys from all three servers, showing whether names are distinct per server and what metadata objects K3s writes |
| Per-node retention | Whether K3s applies retention per server or across all servers' snapshots in the folder |
| Scheduled versus on-demand retention | Whether on-demand snapshots are pruned with scheduled ones, separately, or not at all |
| Delete markers and noncurrent versions | That pruning creates delete markers and leaves noncurrent versions that the lifecycle rule expires after the configured period |
| Noncurrent-version restore | An explicitly selected noncurrent version is copied back (or downloaded by version ID) and restored successfully ([Track A](#rehearsal-tracks)) |
| S3 calls | The S3 calls K3s makes, as needed for the identity policy |

**Token.** The server token is identical on all servers and is mode `0600`. Its recovery copy is `age` ciphertext in `recovery/`; see [Recovery material](#recovery-material-and-client-side-encryption). The token value, and any hash or fingerprint of it, are never printed, logged or recorded. Checks compare plaintext only by exit status (`cmp -s`), never by printing a digest.

**Restore outline** (rehearsed in [Track A](#rehearsal-tracks)):

1. Build a server with homelab-k3s at the same K3s version.
2. As an administrator, download the chosen snapshot from `etcd/`, or copy back a noncurrent version.
3. Decrypt the token into a `0600` file in tmpfs, using the offline `age` identity.
4. Run `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot> --token-file=<file>`. `--token-file` keeps the token out of the process list.
5. Start K3s normally, then remove the token file and tear down the tmpfs. Join further servers only after the restored server is healthy.

A restore from S3 directly through K3s's S3 options is also possible. It needs the etcd identity's `s3:GetObject`, and is tested in the rehearsal.

## Secrets encryption at rest (prerequisite stage)

**Recommendation: enable and rotate K3s secrets encryption as its own stage (Stage 3), before any etcd snapshot is uploaded.**

Why it is a prerequisite, not a follow-up:

- Without it, each uploaded snapshot is a plaintext copy of every Kubernetes Secret, protected only by SSE-S3.
- With it, Secret values in a snapshot are encrypted. The encryption configuration travels in K3s bootstrap data, which is itself encrypted with the token-derived key. An attacker would need both the snapshot and the token, and the token is stored only as `age` ciphertext with an offline key.
- It changes every server's configuration and every Secret in etcd. Mixing it with the S3 upload change would make a failure ambiguous.

**This design does not prescribe the command sequence.** Enabling encryption on an existing multi-server cluster, re-encrypting existing Secrets and rotating keys are each multi-step K3s procedures. They may include prepare, restart, rotate and re-encrypt stages, in an order and with restart requirements that depend on the K3s version. The implementation must follow **the exact multi-server procedure that K3s documents for the installed version, `v1.36.4+k3s1`**, and:

- record the procedure's source and its exact steps in the Stage 3 PR before any live change;
- rehearse that exact sequence, unchanged, on a disposable three-server k3d cluster at the same K3s version, including enabling encryption, re-encrypting existing Secrets, one key rotation and the documented rollback;
- record, at each step, the status every server reports and which restarts were needed;
- **not assume that a simple rolling restart is sufficient** to enable encryption, rotate keys or roll back, unless the documented procedure for this version says so and the rehearsal confirms it.

Live sequence, at the level this design fixes:

1. Preflight:
   - an on-demand local snapshot is taken and recorded;
   - the token's recovery ciphertext has been verified (Stage 2);
   - all Flux Kustomizations are `Ready`.
2. A homelab-k3s PR makes the server-configuration change that the documented procedure requires.
3. The rehearsed procedure is executed exactly as recorded. It covers enabling, re-encrypting existing Secrets and one key rotation, so that the key that coexisted with plaintext data is retired. Any deviation from the recorded steps is a stop condition, not an improvisation.
4. Copy the encryption-recovery material into recovery material as `age` ciphertext, if the rehearsal shows it is separately required. The rehearsal must still establish whether a restore with the matching token recovers it from bootstrap data alone.

Validation:

- `k3s secrets-encrypt status` on every server reports the end state that the documented procedure defines as complete, with matching encryption hashes on all servers;
- `helm list -A`, Flux reconciliation and the Grafana login all work, which proves that existing Secrets still decrypt;
- an on-demand snapshot is taken afterwards.

Raw verification that values are stored with an encryption prefix needs an etcd client, which is a software installation decision for that stage.

Stop conditions:

- any server fails to start;
- encryption hashes differ between servers at a step where the procedure requires them to match;
- any step's result differs from the rehearsal record;
- any API error reading Secrets;
- any Flux Kustomization or HelmRelease not `Ready`.

Rollback:

1. The disable and re-encrypt procedure that K3s documents for the installed version, rehearsed in k3d along with the forward procedure. It is not assumed to be a simple rolling restart.
2. As a last resort, cluster-reset to the preflight snapshot with the matching token.

Snapshots taken before the change contain the old bootstrap data. The rehearsal checks that both pre- and post-rotation snapshots restore.

Key rotation afterwards: annually, after any suspected exposure, and after the loss of any copy of the encryption configuration. Each rotation refreshes the recovery copy.

## Persistent-volume backup: Velero with Kopia

### Evaluation

| Option | Assessment |
| --- | --- |
| **Velero file-system backup with the Kopia uploader** | **Candidate.** Kubernetes-aware, incremental and deduplicating, with client-side repository encryption, schedules with TTLs, S3 support through the AWS plugin, and Prometheus metrics. Costs: a privileged node-agent DaemonSet with host-path access, a broad default RBAC binding, crash-consistent copies only, and additional CRDs and images |
| Velero CSI snapshots or data mover | Not applicable: `local-path` has no CSI snapshot support |
| Application-level dumps | Prometheus's TSDB snapshot API requires enabling the admin API. The Grafana image is distroless, with no shell or `sqlite3` for a hook. Rejected initially |
| Replicated storage (for example, Longhorn) with its own backups | Replaces the storage layer; belongs to the persistent-storage design |
| Accept loss of Prometheus data | Metrics are rebuilt over time with 7-day retention, but the requirement includes Prometheus. Kept as a fallback if the volume backup proves unworkable |

**Blocking question for the rehearsal:** Velero's file-system backup does not support `hostPath` volumes. K3s's `local-path` provisioner creates `hostPath` persistent volumes by default; it can create `local` volumes when configured to. Stage 0 records the volume type of both claims, and the Stage 5 k3d rehearsal, which uses the same provisioner, must show that Velero backs up and restores them. If it cannot, Stage 5 stops and one of these is chosen by amendment:

- recreate the claims with the `local` volume type (a data migration);
- an application-level approach;
- accepting Prometheus data loss and backing up Grafana another way.

### Proposed configuration

- **Version:** chosen at implementation after release-note review. It must list Kubernetes 1.36 as supported; if no release does, that is a stop condition.
- **Install:** Velero Helm chart with the AWS object-store plugin and the node-agent DaemonSet. Volume snapshot locations are disabled. How the chart installs and upgrades CRDs, and every image it pulls, are reviewed before merge.
- **Namespace:** `velero`, with Pod Security `privileged`, because the node-agent mounts the kubelet pods directory from the host. This is an accepted-risk approval, like `monitoring-node-exporter`.
- **RBAC:** the chart binds Velero to `cluster-admin` by default. The k3d rehearsal tests a narrower ClusterRole (read in `monitoring`, persistent volumes, Velero's own resources, and create rights for restore). If that is insufficient, `cluster-admin` is recorded as an accepted risk requiring explicit approval.
- **BackupStorageLocation:**
  - bucket `<backup-bucket>`, prefix `volumes`, region `us-east-1`;
  - **validation frequency 1 hour**. The default of one minute alone would cost about $0.22 a month in LIST requests.
- **Kopia repository password:** set from `velero/velero-repo-credentials` before the first backup. Without that password the repository cannot be read, so it is part of the recovery material.
- **Schedules:**
  - daily at 03:30, namespace `monitoring`, both claims, TTL 7 days;
  - weekly on Sunday at 04:30, Grafana only, TTL 28 days. Prometheus data older than its own 7-day retention has little value, so it is not kept weekly.
- **Volume inclusion is configured deliberately.** Installing the node-agent does not, by itself, mean any claim is backed up: Velero backs up pod volumes only when a backup or pod opts them in. The implementation selects **exactly one** inclusion mechanism supported by the chosen Velero version and records it in the PR:
  - `defaultVolumesToFsBackup: true` on the Schedules, scoped by namespace and label selectors; or
  - explicit pod-volume backup annotations on the Prometheus and Grafana pods, set through the chart values.

  Acceptance requires two proofs, which are recorded:
  - the rendered configuration shows the mechanism applied to both intended PVC-mounted volumes, and to no unintended volume;
  - the completed backup lists a completed pod-volume backup for both the Prometheus claim and the Grafana claim.

  A `Completed` backup without both pod-volume backups is a failed backup.
- **Excluded resources: `secrets`.** Velero stores backed-up resources as plaintext JSON in S3, outside the Kopia repository. Kopia encrypts only the volume data. Out-of-band Secrets are recovered from recovery material instead.
- **Resources:** node-agent and server requests and limits are sized from rehearsal measurements. Node memory use is currently 19–29%.

**Consistency.** Copies are taken from running pods.

- Prometheus's TSDB tolerates this through WAL replay, but the newest head data may be lost.
- Grafana's SQLite database could be caught mid-write, although Grafana writes rarely.

This is crash consistency at best, not application consistency. **A backup is not accepted because Velero reports `Completed`.** It is accepted only when a restore of it passes the integrity checks in [Pass criteria](#pass-criteria):

- Prometheus opens the restored TSDB without corruption or repair failure;
- a query returns samples older than the backup time;
- Grafana opens the restored SQLite database;
- the non-provisioned marker dashboard is still present;
- the restored containers' logs show no WAL, TSDB or SQLite corruption messages.

If any of those checks fails, Stage 5 stops, and the design is amended (for example, to quiesce, use application-level backups, or drop the Prometheus backup) rather than accepting the backup.

**Restore outline** (rehearsed in [Track B](#rehearsal-tracks)):

1. Suspend the `monitoring` Flux Kustomizations.
2. Scale down or remove the workload and its claim.
3. Run a Velero restore of the `monitoring` backup, limited to the claim, the volume and the pods that file-system restore needs.
4. Resume Flux.

Whether Flux and Helm adopt or replace the Velero-restored objects without losing the restored data is a rehearsal question. The answer is written into the restore runbook.

## Recovery material and client-side encryption

| Item | Source | Changes when |
| --- | --- | --- |
| K3s server token | `/var/lib/rancher/k3s/server/token` (mode `0600`) | Token rotation |
| K3s secrets-encryption recovery material, if Stage 3 shows it is separately required | The server's credential directory, after Stage 3 | Each key rotation |
| Grafana admin credential | The protected out-of-band credential file | Password change |
| Velero repository password | Generated out of band in Stage 5 | Never, unless deliberately rotated |

**Tool: `age`**, with an X25519 recipient key.

- Encryption needs only the public recipient, so the hosts that encrypt never hold a decryption secret.
- The private identity is created offline. **An ordinary `age` X25519 identity file is plaintext; it is not passphrase-protected by default.** The Stage 2 runbook must use, and test, one documented protection method before the identity is stored:
  - the identity file is itself encrypted with an approved passphrase-based `age` workflow, and the plaintext identity exists only in tmpfs during use; or
  - the identity is kept only on appropriately protected offline encrypted media.

  Either way, two separate offline copies are kept, one away from the cluster's site. The runbook test must prove that each stored copy can be unlocked and that it decrypts a test ciphertext. The test records only the outcome.
- The public recipient may be committed for use by scripts; see [Open decisions](#open-decisions).

**Handling rules.** No plaintext token, Grafana password, access key or encryption password may enter Git, logs or evidence.

- Encrypt on the host that holds the secret, reading the source file directly, for example `age -r <recipient> -o <name>.age <source>`. Never pipe secrets through `echo`, put them on a command line, or display them.
- Only ciphertext leaves the source host. It is copied to the administrator workstation and uploaded to `recovery/` in an SSO session using the routine permission set ([Human access](#human-access)). Machine identities cannot read or write `recovery/`.
- `umask 077`, shell tracing off, no `--debug`, and history disabled for the session.
- Decrypted plaintext exists only in tmpfs. After use, it is removed and that temporary environment is torn down: the tmpfs is unmounted, or the disposable host is destroyed. `shred` is not relied on: it does not guarantee secure deletion on SSD-backed or copy-on-write storage, which is why plaintext never touches persistent disk.
- Verification:
  - immediately after upload, download the object;
  - decrypt it only on a host that already holds the plaintext, into memory-backed storage;
  - compare it with `cmp -s`, recording only the exit status.

  No digest of any plaintext is computed for the record. Ciphertext SHA-256 values may be recorded, because `age` output is randomized and reveals nothing about the plaintext.
- Object names describe the item and date only, for example `recovery/k3s-server-token/2026-10-20.age`.

A verified recovery copy shows that the ciphertext decrypts to the current value. It does not show that a restore using it works; only a rehearsal does.

### Recovery-material inventory

The individual files are not enough to rebuild from. A recovery-material inventory records everything a restore needs, and where each item is. **It contains no secret values**: it points to secrets and records their verification state, but never holds them.

The blank template is part of the Stage 2 runbook in Git. A filled copy is kept with the recovery material as `age` ciphertext, plus an offline copy. The filled copy is kept out of Git, because it holds backup identifiers and version IDs. It is updated whenever an item changes, and reviewed quarterly.

| Item | Recorded in the inventory (never the secret itself) |
| --- | --- |
| K3s server token | Recovery object key; date of the last verification by `cmp -s` |
| K3s secrets-encryption recovery material | Whether Stage 3 showed it to be separately required; if so, the object key and verification date |
| Grafana admin credential | Recovery object key; verification date; the Secret name it recreates |
| Velero/Kopia repository password | Recovery object key; verification date; the Secret name it recreates |
| Storage map | Bucket name, region, and the prefix map (`etcd/`, `volumes/`, `recovery/`, `evidence/`) |
| Selected backups | The etcd snapshot names and S3 version IDs, and the Velero backup names, chosen as the current restore points |
| Tool versions | K3s, Velero, the Velero AWS plugin, Kopia (as bundled with Velero), `age`, the AWS CLI |
| Git revisions | The homelab-k3s and home-cluster revisions to rebuild from |
| Offline `age` identity | Where the two protected copies are kept, which protection method is used, and the procedure to unlock them, without the passphrase |
| Access path | The IAM Identity Center permission set used for recovery (by name only); no account ID, portal identifier or personal email address |
| External dependencies | Pointer to the Stage 0 inventory of [external dependencies](#external-dependencies-for-a-full-rebuild) |

## Recovery objectives

The targets are design targets. **None has been measured.** The rehearsal records actual times and recovery points, and these targets are revised to match the evidence.

| Asset | RPO target | RTO target | Basis |
| --- | --- | --- | --- |
| Declarative manifests | Last commit pushed to GitHub | Part of the rebuild | Flux reconciles from Git |
| etcd cluster state, including out-of-band Secrets and Helm history | 12 hours | 4 hours from a built, empty server to a restored, `Ready` API | Twice-daily snapshots |
| Recovery material | Zero for recorded changes: re-encrypted and uploaded at each change | 30 minutes, given the offline `age` identity | Manual upload on change |
| Grafana volume | 24 hours | 1 hour after the cluster is `Ready` | Daily schedule |
| Prometheus volume | 24 hours | 2 hours after the cluster is `Ready` | Daily schedule; loss is tolerable |
| Whole-site loss (all three nodes) | 12 hours for cluster state; 24 hours for volumes | 1 day, including VM rebuild with homelab-k3s | Sum of the above, plus provisioning |

Before risky changes, on-demand snapshots continue to provide a fresher local recovery point.

## Retention schedule

| Data | Frequency | Local retention | Off-cluster retention | Noncurrent history |
| --- | --- | --- | --- | --- |
| etcd snapshots | 00:00 and 12:00 node time, on each server | 5 per node (about 2.5 days) | Intended: 5 per node, pruned by K3s (rehearsal assertion) | 14 days (intended) |
| On-demand etcd snapshots | Before risky changes | As K3s handles them (rehearsal assertion) | As K3s handles them (rehearsal assertion) | 14 days (intended) |
| Prometheus volume | Daily 03:30 | None | 7 days (Velero TTL) | 7 days |
| Grafana volume | Daily 03:30; weekly Sunday 04:30 | None | 7 days daily; 28 days weekly | 7 days |
| Recovery material | On change; reviewed quarterly | Offline `age` identity only | Indefinite for the current version | 90 days |
| Rehearsal evidence | Per rehearsal | Outside the repository, as existing practice | 365 days | 30 days |

Velero schedules avoid the etcd snapshot times.

## Cost estimate

**Every quantity in this section is a planning assumption, not a measurement.** That includes the snapshot sizes, the request counts and the Kopia repository growth. The arithmetic is exact; the inputs are not.

- **Stage 1 must recheck current official AWS pricing** for every rate below before anything is created, and update this estimate if any rate differs.
- **After the first full month of operation, the Cost Explorer and billing results are compared with this estimate**, line by line where the data allows. The comparison is recorded in the validation record, and this section is amended.

Published `us-east-1` on-demand list prices, as assumed for planning:

- S3 Standard storage: $0.023 per GB-month;
- PUT, COPY, POST and LIST: $0.005 per 1,000;
- GET: $0.0004 per 1,000;
- data transfer in: free;
- data transfer out to the internet: the first 100 GB a month is free, then $0.09 per GB.

Free-tier allowances other than that data-transfer allowance are not counted on.

**Size assumptions** (planning assumptions; measured in Stage 0 and after each stage):

- an etcd snapshot is at most 100 MB uncompressed;
- the Kopia repository holds about 12 GB of unique data for seven daily Prometheus restore points, given TSDB compaction churn, plus 4 GB of noncurrent blobs.

| Item | Quantity | Monthly cost |
| --- | --- | --- |
| etcd current snapshots | 3 nodes × 5 × 0.1 GB = 1.5 GB | $0.035 |
| etcd noncurrent versions | 6 per day × 14 days × 0.1 GB = 8.4 GB | $0.193 |
| Kopia repository, current | 12 GB (assumed growth) | $0.276 |
| Kopia repository, noncurrent | 4 GB (assumed) | $0.092 |
| Recovery material and evidence | 0.1 GB | $0.002 |
| **Storage subtotal** | **26.0 GB** | **$0.598** |
| PUT/LIST requests | 25,000 (assumed allowance; itemized below) | $0.125 |
| GET requests | 50,000 (assumed) | $0.020 |
| **Expected steady state** | | **$0.743** |
| Optional CloudWatch alarms | 2 × $0.10 | $0.200 |
| Restore-rehearsal download in a rehearsal month | About 4.5 GB; $0 within the free allowance, otherwise at $0.09 per GB | up to $0.405 |
| **Expected maximum in a rehearsal month** | | **$1.348** |

Request allowance per month (planning assumptions; the per-run request counts are not measured):

- etcd: about 1,800 (6 snapshots a day × about 10 requests × 30 days);
- BackupStorageLocation validation: 720 (hourly);
- Kopia maintenance: about 14,400 (an assumed 20 requests per hourly run);
- daily backups: about 6,000.

That totals about 23,000, so 25,000 is allowed.

**Sensitivity to the planning assumptions.**

- Snapshots of 500 MB instead of 100 MB add about $0.91.
- A Kopia repository twice the size adds about $0.37.

Together, the rehearsal-month maximum would reach about $2.63, which is still below $5.

What would breach the budget:

- about 200 GB of stored data (about $4.60 a month);
- about one million PUT/LIST requests (about $5), for example a crash-looping client.

The existing budget alerts are the guard for both. A separate S3-filtered budget is an option; see [Open decisions](#open-decisions).

**Customer-managed KMS key, for comparison:** an additional $1.00 per month, plus request charges.

## Monitoring and alerting

| Signal | Source | Alert condition (candidate) |
| --- | --- | --- |
| etcd off-cluster freshness | `ETCDSnapshotFile` objects, exposed through the kube-state-metrics custom-resource configuration planned in observability Phase 4 | No S3-located, ready snapshot newer than 14 hours |
| etcd snapshot failure | `ETCDSnapshotFile` status errors and K3s events | Any snapshot with an error in the last 24 hours |
| Velero backup freshness | Velero metrics (last successful backup timestamp per schedule) | Older than 26 hours (daily) or 8 days (weekly) |
| Velero failures | Velero failure and partial-failure counters | Any increase |
| Storage location | Velero storage-location status | `Unavailable` for 2 hours |
| Access key age | IAM credential report (monthly, manual) | Older than 90 days |
| Cost | Existing organization budget alerts | As configured |

Metric names are candidates. As in the observability design, each rule must return data in the rehearsal, or it is removed.

Two gaps are stated rather than hidden:

- **Alert delivery does not exist yet** (observability open item). Until it does, these alerts are visible only in the Prometheus and Alertmanager UIs, and unattended backup operation cannot be claimed.
- **In-cluster alerts cannot report the disaster they exist for.** If the cluster is gone, nothing fires. Until an external freshness check exists, a **weekly manual check** applies. It is run from an SSO session and records the newest object time under `etcd/` and `volumes/`. Automating it is an [open decision](#open-decisions).

## Failure handling

| Failure | Effect | Handling |
| --- | --- | --- |
| S3 upload fails (network, permissions, S3 error) | Local snapshot exists; no off-cluster copy for that cycle | Alert after one missed cycle. Do not widen permissions without an amendment. Retry with an on-demand snapshot after the fix |
| Machine key revoked, deactivated or expired | Uploads for that path stop | Rotate; verify with on-demand backups |
| One server down | The other two still upload | Normal; no action for backups |
| Velero backup `PartiallyFailed` | Some volume data missing from that point | Investigate before the next run; the previous points remain |
| Kopia repository error | Volume backups stop | Repository maintenance or reconnect. Never apply lifecycle expiration to fix it |
| Velero repository password lost | Repository unreadable | Recover from recovery material. If that is also lost, start a new repository and treat older points as lost |
| Offline `age` identity lost | Recovery material unreadable | Create a new identity. Re-encrypt from the live sources while the cluster still exists. Rotate the token and encryption key if exposure is suspected |
| Bucket policy or lifecycle misconfigured | Writes denied, or history removed too early | Detected by the freshness alerts and the weekly check. Fix through the IaC PR |
| Unexpected cost | Budget alert | Suspend the Velero schedules and remove the K3s S3 option. Investigate request and storage metrics |
| Clock skew on a node | AWS signatures rejected | Preflight checks time synchronization on every node |

## Implementation plan (one concern per PR)

The requested order was:

1. AWS storage and IAM;
2. etcd off-cluster backups;
3. encrypted recovery material;
4. volume backups;
5. restore rehearsal;
6. evidence and documentation.

This design proposes two changes, **which need approval**:

- **Recovery material moves before the etcd uploads.** An off-cluster snapshot without a recoverable token is not a backup. Stage 3's rollback also depends on the token.
- **A secrets-encryption stage is added before the etcd uploads.** Without it, snapshots would put plaintext Secrets in S3.

| Stage | Concern | PR content | Live changes |
| --- | --- | --- | --- |
| 0 | Preflight | None | None (read-only) |
| 1 | AWS storage and IAM | IaC template for the bucket, its policy, lifecycle and protections, the two IAM users and their policies. **No access keys.** The definition of the routine least-privilege permission set ([Human access](#human-access)). Static checks for account IDs and key patterns | Bucket and IAM users created through the existing administrator session; the routine permission set created or approved |
| 2 | Encrypted recovery material | Runbook and a helper script for encrypt, upload and verify; the public `age` recipient if approved | Ciphertext of the token and the Grafana credential uploaded and verified |
| 3 | Secrets encryption at rest | homelab-k3s server configuration; the documented K3s procedure for `v1.36.4+k3s1`, recorded step by step; runbook and evidence here | The rehearsed multi-server procedure (enable, re-encrypt, one key rotation); encryption-recovery material added to the recovery material if separately required |
| 4 | etcd off-cluster backups | homelab-k3s drop-in for S3 upload (credentials from encrypted variables); the freshness rule here, if the observability Phase 4 custom-resource metrics exist | Etcd access key created; snapshots uploaded |
| 5 | Volume backups | `backup.yaml` and `clusters/home/backup/`; CI catalog update for Velero CRDs; Pod Security and RBAC checks | Velero installed; Velero key and repository password created out of band beforehand; schedules start |
| 6 | Restore rehearsal | None, or harness fixes outside the repository | Isolated environment only; see [Isolated restore rehearsal](#isolated-restore-rehearsal) |
| 7 | Evidence and documentation | `docs/validation/backup-disaster-recovery.md` and README status, limited to the evidence | None |

Stages 2–5 each start with a fresh on-demand local etcd snapshot as their recovery point.

**Human access gate.** From Stage 2 onwards, routine actions (recovery-material and evidence uploads, inventory checks, rehearsal downloads) use the routine permission set, not `AdministratorAccess`. `AdministratorAccess` remains for provisioning and break-glass only. Scheduled backup operation is not considered complete until the routine permission set exists and has been used successfully for a recovery-material upload, an inventory check and a rehearsal download.

## Pre-merge validation

### Static (every PR)

- Existing CI: gitleaks, yamllint, Kustomize render, kubeconform with the `flux-system` root guard, and the targeted observability checks.
- New checks:
  - no 12-digit AWS account ID, access-key-shaped string, `age` secret key or K3s token-shaped string anywhere in the change;
  - every image tag explicit;
  - no `Secret` manifests under `backup/`.
- Stage 1: template linting; IAM Access Analyzer policy validation, from an SSO session at implementation time; review against the policy table above.
- Stage 5:
  - `helm template` of the Velero chart with the proposed values, validated with kubeconform against the Velero CRDs;
  - Kustomization membership;
  - Pod Security labels;
  - the RBAC binding.

Static checks do not show S3 behavior, IAM sufficiency or recoverability.

### Disposable k3d rehearsal (before Stages 3–5 merge)

The rehearsal uses MinIO in the k3d cluster as the S3-compatible target, so no AWS credentials enter it.

- **Stage 3:** a three-server k3d cluster at the same K3s version. Execute the exact documented procedure recorded in the Stage 3 PR: enable, re-encrypt, one rotation, and rollback. Record each server's status and the restarts each step needed, and restore pre- and post-rotation snapshots with the matching token.
- **Stage 4:** K3s uploads to MinIO, retention pruning and restore from an uploaded snapshot.
- **Stage 5, on the same `local-path` provisioner:**
  - the volume-type question above;
  - backup and restore of both claims;
  - excluded Secrets;
  - the narrower RBAC attempt;
  - Pod Security admission;
  - metric names for the alert rules;
  - resource peaks;
  - Flux and Helm behavior on restore.

Evidence boundaries: k3d and MinIO do not test AWS IAM evaluation, bucket policies, real S3 lifecycle or latency, VMware, or real multi-node failure.

## Live preflight, stop conditions and rollback

### Stage 0: preflight (read-only)

| Check | Pass condition |
| --- | --- |
| Baseline snapshot, using the split design's procedure | All Kustomizations `Ready=True`; the record is saved |
| K3s version and options | `v1.36.4+k3s1`; S3 snapshot and secrets-encryption options present |
| Local snapshots | `k3s etcd-snapshot ls` shows the schedule working; sizes recorded for the cost estimate |
| Token file | Exists with mode `0600` (`stat` only; never read) |
| Secrets encryption | Status recorded as disabled |
| Claim volume type | `hostPath` or `local` recorded for both claims |
| Node egress and time | HTTPS to the regional S3 endpoint works without credentials; time synchronized on every node |
| AWS (SSO session) | Region; no bucket of the chosen name; account Block Public Access state; budget present; no organization policy blocks S3 or IAM |
| Rehearsal environment | Isolated network and resources available (for Stage 6) |
| External rebuild dependencies | Each [external dependency](#external-dependencies-for-a-full-rebuild) inventoried: VMware, network and DNS configuration needed for a rebuild is located in a recoverable record, or listed as a recovery gap |

### Stop conditions (after any stage's live change)

| Observation | Action |
| --- | --- |
| Any credential-shaped value in logs, events, evidence or Git | Treat it as compromised: deactivate and rotate; follow SECURITY.md. Stop the stage |
| A K3s server fails to start, or any node is not `Ready` | Roll back that server's change |
| Any Flux Kustomization or HelmRelease not `Ready` | Roll back the stage |
| `AccessDenied` for a designed action | Stop. Fix within the design, or amend it; do not widen ad hoc |
| IAM Access Analyzer reports external or public access | Stop and fix before anything uses the bucket |
| Node `MemoryPressure` or `DiskPressure`, or sustained LAN monitor failures to `10.0.0.220` (more than 30 s) | Roll back the stage |
| S3 cost above $0.50 on any day, or any budget alert | Suspend uploads and schedules, then investigate |

### Rollback (per stage)

| Stage | Rollback |
| --- | --- |
| 1 | Nothing uses the bucket yet. Follow [Teardown](#teardown) |
| 2 | Delete the uploaded ciphertext versions as an administrator. Nothing changes on the cluster |
| 3 | As in [Secrets encryption at rest](#secrets-encryption-at-rest-prerequisite-stage) |
| 4 | Revert the homelab-k3s drop-in and roll-restart. Local snapshots continue. Deactivate the etcd key. S3 objects remain until teardown |
| 5 | Revert the PR; Flux prunes Velero. The CRDs remain until deliberately removed. Delete the out-of-band Secrets and deactivate the Velero key. Objects in S3 remain, since deleting Velero resources does not delete them |
| 6 | Destroy the rehearsal environment and delete the rehearsal credential |
| 7 | Revert the documentation |

### Post-merge validation (each stage)

- The snapshot comparison shows no unintended change to existing objects, their UIDs, or Helm revisions.
- All Kustomizations are `Ready=True` at the merge revision.
- The LAN monitor stayed clean through the change window.
- **Stage 4:**
  - an on-demand snapshot and the next scheduled snapshot appear under `etcd/` from each server;
  - the retention assertions from Stage 4 (naming, per-node retention, on-demand handling, delete markers and noncurrent versions) are recorded as observed in S3;
  - no key-shaped string appears in the K3s journal.
- **Stage 5:**
  - the storage location is `Available`;
  - an on-demand backup and the first scheduled backup are `Completed`, with zero errors;
  - the backups contain no Secrets;
  - the node-agent resource use is recorded.
- Monthly: compare actual cost against the estimate.

None of these checks demonstrates recoverability.

## Isolated restore rehearsal

### Isolation requirements

A restored cluster contains production configuration: MetalLB announcing `10.0.0.220`, the kube-vip address, Flux credentials, and the Velero credential and storage location. The rehearsal must not be able to affect production.

- **Network:** a separate VMware port group or VLAN with no layer-2 adjacency to the LAN, so restored MetalLB and kube-vip cannot answer ARP for production addresses. No egress, except as stated for Track B.
- **Staging:** artifacts (snapshot, ciphertext) are placed on the rehearsal VMs before K3s starts. Any staging interface is removed before the restore.
- **Credentials:** the rehearsal never uses the production machine keys. Volume restore uses a **dedicated, read-only rehearsal identity** (`s3:GetObject` and `s3:ListBucket` on `volumes/` only). It is created for the rehearsal and deleted afterwards.
- **Teardown:** the rehearsal VMs are destroyed afterwards. Evidence is collected with `umask 077` and credential-scanned before archiving.

### Rehearsal tracks

| Track | What is restored | Method |
| --- | --- | --- |
| A: etcd and token | Cluster state on a fresh single server | The snapshot is downloaded using the routine permission set; the token is decrypted from `recovery/` with the offline identity; cluster-reset restore with `--token-file`; no egress. Repeated for a noncurrent snapshot version and for a pre- and post-rotation snapshot |
| B: volumes | Prometheus and Grafana data in a fresh, non-restored isolated cluster | Velero installed with the storage location in `ReadOnly` mode and the read-only rehearsal identity. Egress limited to S3 |
| C: end to end | Both, in one cluster | The [end-to-end restore order](#end-to-end-restore-order) below |

If Velero or Kopia needs write access to restore from a read-only location, the rehearsal records it. The fallback is a local S3-compatible copy of `volumes/` inside the isolated network, which needs no egress at all.

### End-to-end restore order

Track C, and any real full rebuild, follow this order. A step does not start until the previous one has passed.

1. **Provision isolated replacement infrastructure** with homelab-k3s, on a network with no production LAN adjacency and no egress.
2. **Stage the snapshot, the token and the required recovery material**, using the [recovery-material inventory](#recovery-material-inventory): the selected snapshot (by name and, if noncurrent, version ID) and the ciphertexts. Staging happens before K3s starts; any staging interface is then removed.
3. **Restore one K3s server** from the snapshot with the decrypted token (`--token-file`, plaintext in tmpfs only), still without production LAN adjacency.
4. **Neutralize restored external integrations and backup writers** before any network access is granted:
   - suspend Flux's `backup` Kustomizations;
   - scale Velero to zero;
   - set the restored storage location to `ReadOnly`;
   - replace the restored Velero Secret with the read-only rehearsal identity.

   The rehearsal also records which other restored integrations (MetalLB, kube-vip, Flux sources) are active, and confirms that the isolation contains them.
5. **Validate the API and Secret decryption**: the Track A criteria.
6. **Add the remaining servers**, if the rehearsal scope includes them. Otherwise, record that the rehearsal restored a single server.
7. **Restore the PVC data** with Velero: the Track B procedure, using only the S3 egress approved for it.
8. **Validate Prometheus, Grafana, Flux and the canary**: the Track B criteria, plus Flux object state and the canary Deployment and endpoints inside the isolated network.
9. **Enable only deliberately approved network access.** Each change to isolation is recorded, and none gives the rehearsal layer-2 adjacency to the production LAN.
10. **Record the measured RPO and RTO, then destroy the rehearsal environment**, including the rehearsal identity and every tmpfs that held plaintext.

### Pass criteria

**Track A:**

- K3s starts from the snapshot and the API is `Ready`.
- Namespaces, Flux objects, HelmReleases and the canary Deployment are present, and the seven platform objects' UIDs match the baseline taken at snapshot time.
- Secrets decrypt: `helm list -A` works, and `monitoring/grafana-admin` exists. Its value is compared with the source only by `cmp -s` exit status.
- The snapshot's age at restore (the measured RPO) and the time to API `Ready` (the measured RTO) are recorded.

**Track B:**

- The source backup contained completed pod-volume backups for both claims, and the Velero restore is `Completed` with zero errors; any warnings are recorded. **This alone is not a pass.**
- Prometheus opens the restored TSDB without a corruption or repair failure. A query returns samples with timestamps **older than the backup time**, and the oldest restored sample time is recorded.
- Grafana opens the restored SQLite database and starts. The admin login works with the credential from recovery material. A deliberately created, non-provisioned marker dashboard, made before the backup, is present.
- The restored Prometheus and Grafana container logs are checked for WAL, TSDB and SQLite corruption or repair messages, and none is found. The search terms used are recorded with the evidence.
- The restore time is recorded.

If any Track B check fails, the rehearsal stops and the design is amended. The backup is not accepted.

**Track C:**

- every step of the [end-to-end restore order](#end-to-end-restore-order) is completed in sequence;
- both sets of criteria pass in one cluster;
- a record shows that no write reached the bucket from the rehearsal (an object listing before and after).

Only Track C supports a claim of disaster recovery for the cluster state and the two volumes. Even then, the claim is scoped to what was restored, on the rehearsal's single server.

## Teardown

Removing the off-cluster copy is deliberate and recorded, and it requires explicit approval. Local snapshots remain the only copy afterwards.

1. Stop writers: revert Velero (Stage 5) and the K3s S3 drop-in (Stage 4), and confirm that no new objects appear for one schedule cycle.
2. Deactivate, then delete, both machine access keys and any rehearsal identity.
3. Download anything to be kept, such as recovery ciphertext or evidence, to its approved offline location.
4. Remove the `DenyBucketDeletion` statement. This is the first deliberate destructive step.
5. Empty the bucket, including all object versions and delete markers. Either use a temporary lifecycle rule (expire current and noncurrent versions after 1 day) and wait, or delete versions explicitly as an administrator.
6. Delete the bucket. Remove the stack's termination protection, then delete the stack; the retained bucket is already gone.
7. Verify: the bucket and IAM users no longer exist, and S3 charges stop on the following days' bill.
8. Record the teardown, with timestamps, in the validation record.

## Evidence handling

- Evidence files are stored outside the repository and identified by name and SHA-256, as in existing validation records. They are optionally also uploaded to `evidence/` by an administrator.
- **Never captured:**
  - plaintext secrets;
  - decrypted files;
  - digests of plaintext secrets;
  - access key IDs or secret keys;
  - the account ID;
  - portal or SSO identifiers.

  Evidence records AWS resources by logical name (for example, "the backup bucket" or "the etcd identity").
- Before archiving, every evidence directory is scanned for:
  - access-key-shaped strings;
  - `age` secret keys;
  - K3s token-shaped strings;
  - 12-digit numbers in ARN context;
  - the throwaway rehearsal credentials.

  A match blocks archiving and triggers the leaked-secret procedure.

## Evidence boundaries and claims not to make

Once implemented and validated, the evidence may support:

- that scheduled etcd snapshots and volume backups reach S3 with the designed permissions and protections;
- what the rehearsals actually restored, on what environment, with the measured recovery points and times;
- that recovery material was encrypted client-side and verified by decryption comparison.

Do **not** claim:

- **recoverability from uploads, checksums or listings alone.** They show that bytes exist, not that a restore works;
- **complete disaster recovery before Track C passes.** Before that, claim at most what Track A or Track B separately showed;
- that the RPO or RTO targets are met before they are measured;
- immutable, ransomware-proof or administrator-proof backups. There is no Object Lock, and the account administrator and root can delete everything;
- protection against `us-east-1` outages, or against loss or compromise of the AWS account;
- application-consistent Prometheus or Grafana backups;
- unattended backup operation, before alert delivery and an external freshness check exist;
- that a three-node rebuild works, if the rehearsal restored to one server;
- that the cost estimate is accurate, before a month's bill confirms it;
- recoverability of anything whose recovery material, or the offline `age` identity, is unavailable.

## Assumptions to verify

1. K3s server configuration, including drop-ins, is managed by homelab-k3s, and changes there are made by PR.
2. The installed K3s version supports:
   - S3 snapshot upload with a folder and region;
   - retention pruning in S3, with behavior as listed under the rehearsal assertions;
   - compressed snapshots;
   - `--token-file` with cluster reset;
   - a documented multi-server procedure for enabling Secret encryption, re-encrypting and rotating keys.

   Each is verified against `v1.36.4+k3s1`, not assumed from documentation of other versions.
3. K3s does not store the S3 access key in etcd objects (`ETCDSnapshotFile`, the `k3s-etcd-snapshots` ConfigMap).
4. K3s bootstrap data in a snapshot includes the encryption configuration, so a token-matched restore recovers it. The separate recovery copy is a safeguard.
5. The `local-path` claims are `hostPath` volumes (the provisioner's default). If so, Velero file-system backup may not support them.
6. Snapshot sizes and Kopia repository growth are within the cost-model assumptions. Both are measured.
7. Published prices are as stated. They were not re-fetched for this draft and are re-verified at Stage 1.
8. An isolated VMware network and enough host resources for at least one rehearsal server exist, or can be created.
9. No organization policy (SCP) in the member account blocks the designed S3 or IAM actions.
10. Velero has a release that supports Kubernetes 1.36 when Stage 5 starts.

## Open decisions

1. **Stage order:** resolved — recovery material precedes etcd uploads, with secrets encryption as a prerequisite.
2. **Encryption setting:** resolved — SSE-S3 (`AES256`).
3. **AWS provisioning tool and location:** resolved — CloudFormation in this repository under `aws/backup/`, outside `clusters/`, deployed through SSO.
4. **Committed identifiers:** whether the bucket name (needed by the Velero storage location under Flux) and the public `age` recipient are committed. Neither is a secret; the account ID is never committed.
5. **etcd identity granularity:** resolved — one shared identity.
6. **Key-expiry backstop:** whether to add the `aws:CurrentTime` condition that ends grants 120 days after each rotation.
7. **Alert delivery and external freshness check:** the backup design depends on alert delivery for unattended operation. Choose an external freshness check, for example a scheduled read-only check from a host outside the cluster, or keep the weekly manual check.
8. **Rehearsal environment:**
   - the isolated network design;
   - for Track B and Track C, S3 egress with a read-only identity (recommended, because it tests the real AWS path), or a local S3-compatible copy.
9. **Prometheus volume backup:** keep it, if the rehearsal proves it works, at about $0.37 a month of the estimate; or accept losing up to 7 days of metrics and back up Grafana only.
10. **etcd snapshot compression:** enable it (recommended) and rehearse a compressed restore.
11. **S3 Object Lock:** reconsider in governance mode after the first rehearsal.
12. **Logging:** CloudTrail data events for `recovery/` only (low volume, small cost), or none. Confirm whether an organization trail already records management events for the member account.
13. **Routine permission-set details:** resolved for Stage 1 — the least-privilege action list is defined in CloudFormation, and the rehearsal-only identity remains an administrator task.
14. **Offline storage of the `age` identity:** the two locations, and who holds them.
15. **Cost guard:** whether to add an S3-filtered budget, for example $2, in the management account, in addition to the organization-wide $10 budget.
