# AWS backup foundation validation

## Scope

This record documents the observed results of Stage 1 of the [backup and disaster recovery design](../design/backup-disaster-recovery.md): deploying the AWS backup foundation defined in [`aws/backup/`](../../aws/backup/README.md) and checking it against the design.

All evidence below was supplied by the repository owner. It was not independently accessed while this record was prepared. The evidence file is stored outside this repository; it is identified by file name and SHA-256.

This record contains no AWS account IDs, ARNs, IAM Identity Center identifiers, principal IDs, email addresses, portal URLs, credentials or private deployment-state content. The generated bucket name is not recorded.

Stage 1 provisioned and validated only the AWS foundation. No machine access keys exist, no backup data or recovery material has been uploaded, no cluster configuration changed, and no restore has been rehearsed. Nothing here shows that a backup exists or that the cluster is recoverable.

## Implementation

| Item | Value |
| --- | --- |
| Pull request | #17, `feat: define AWS backup foundation` |
| Merge and deployed revision | `59796f35b9fd6b4b008dd72fd5234a697d1384c6` |
| Deployment date | 2026-10-15 |
| Region | `us-east-1` |
| Member-account stack | `home-cluster-backup-foundation`, from `member-account.yaml` |
| Management-account stack | `home-cluster-backup-operations`, from `management-account.yaml` |

## Evidence

| File | SHA-256 |
| --- | --- |
| `phase7-stage1-aws-live-validation-20261015T163731Z.txt` | `E48845956E77BA3D27D0DB4E11848EB4273B9EB2B64EFD9EC24677F9FA241F5F` |

The file is a sanitized record. Raw transcripts are not stored in Git.

## Pre-deployment validation

| Check | Observed |
| --- | --- |
| GitHub checks on PR #17 | Passed |
| `aws cloudformation validate-template` | Accepted both templates |
| IAM Access Analyzer, through `cfn-policy-validator` on both complete templates | `BlockingFindings: []` and `NonBlockingFindings: []` for each template |
| Organizations service control policies | No blocking SCP on the applicable path |

AWS pricing was not re-verified as part of this evidence. The design's [cost model](../design/backup-disaster-recovery.md) still rests on its stated planning prices.

## Member-account stack

| Check | Observed |
| --- | --- |
| Stack status | `CREATE_COMPLETE` |
| Bucket versioning | `Enabled` |
| Default encryption | `AES256` (SSE-S3) |
| S3 Block Public Access | All four settings `true` |
| Object ownership | `BucketOwnerEnforced` |
| Bucket policy status | `IsPublic: false` |
| Lifecycle rules | 6 rules present |
| Machine IAM users | `home-cluster-etcd-backup` and `home-cluster-velero` both exist |
| Inline policies | The expected inline policy is attached to each user |
| Access keys | Zero for each machine user; none were created |
| Objects | None uploaded |

The lifecycle rule count was observed; the contents of each rule and each bucket-policy statement were not individually verified live.

## Management-account stack

| Check | Observed |
| --- | --- |
| Stack status | `CREATE_COMPLETE` |
| Permission set | `HomeClusterBackupOperator` |
| Session duration | `PT2H` |
| Inline policy | Its action set exactly matched the template |
| Assignment | Verified to the dedicated backup-operator group |

`AdministratorAccess` was not removed. `HomeClusterBackupOperator` is an additional role for routine work; administrator access remains for provisioning and break-glass work, as the design's [access table](../design/backup-disaster-recovery.md) describes.

## Routine-role test

The test ran from the `home-cluster-backup-operator` profile. STS confirmed that the session had assumed the `HomeClusterBackupOperator` role.

| Operation | Expected | Observed |
| --- | --- | --- |
| Read bucket versioning | Allowed | Succeeded; returned `Enabled` |
| Retrieve the bucket policy | Denied | Denied |

No write operation was attempted. No other allowed or prohibited operation was tested.

## What this record does not show

- That any machine identity can upload, because no access keys exist.
- That K3s or Velero can write to the bucket, or that anything written can be restored.
- That the bucket policy's deny statements stop the machine users in practice.
- That the routine role's other permissions, or its other denials, behave as designed.
- Recoverability of any kind. See [Evidence boundaries](../design/backup-disaster-recovery.md#evidence-boundaries-and-claims-not-to-make).
