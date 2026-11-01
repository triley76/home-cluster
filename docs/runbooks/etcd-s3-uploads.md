# Runbook: etcd S3 uploads (Stage 4)

**Status: S4-1, static only.** Nothing in this runbook has been run. No access key exists for the etcd identity, the Stage 1 stack has not been updated, and no node is configured to upload. Each step below runs only at its own gate in the [Stage 4 gates](../design/backup-disaster-recovery.md#stage-4-gates), with its own approval.

This runbook covers the AWS and workstation side of [Stage 4](../design/backup-disaster-recovery.md#stage-4-etcd-off-cluster-uploads-s4-0-design):
- the stack update for [D2](../design/backup-disaster-recovery.md#d2-identity-scope-option-1-accepted) and its read-only checks;
- creating, rotating and revoking the etcd identity's access key;
- the weekly freshness check.

The node side, meaning the drop-in, the restarts, the on-demand uploads and the leak checks, is done by the homelab-k3s `etcd-s3` playbooks and documented in homelab-k3s `docs/etcd-s3-uploads.md`.

## Rules for every step

- **Never print or record:**
  - the bucket name, account ID, ARNs or SSO identifiers;
  - access-key IDs or secrets;
  - object version IDs, object metadata (`x-amz-meta-*`) or ETags;
  - raw AWS errors.
- **Evidence** records counts, ages, exit statuses and the decisions listed here, nothing else.
- **The bucket name** comes from the existing `0600` file `~/.config/home-cluster/backup-bucket`, the same file the recovery-material helper uses.
- **Shell tracing is off** (`set +x`), the AWS CLI's `--debug` is never used, and swap is off while a key exists on the workstation.
- **Keep WSL running** while the key's tmpfs exists. Start the keep-alive in its own terminal, as in the [recovery-material runbook](encrypted-recovery-material.md); WSL unmounts every tmpfs when its virtual machine stops.
- **Never upload, delete or overwrite anything under `etcd/`** with an administrator or routine session. Only K3s writes there.

## Gate 9: the stack update and its checks

An administrator updates the Stage 1 stack from `aws/backup/member-account.yaml` at the reviewed commit, with `CAPABILITY_NAMED_IAM`, after creating and reviewing a change set. The change set must contain exactly one modification, the `EtcdBackupUser` inline policy, with no replacement. Any other change stops the gate.

Then, read-only:

1. **The bucket controls** are unchanged: versioning, encryption, public-access block, ownership, lifecycle and the bucket policy, compared as in the [Stage 1 validation](../validation/aws-backup-foundation.md).
2. **The etcd identity still has no access key.**
3. **A policy simulation** of the etcd identity, with the current bucket policy as the resource policy. The output goes into a private tmpfs, and only the decisions are reported:

   | Action | Resource | `s3:prefix` | Expected |
   | --- | --- | --- | --- |
   | `s3:ListBucket` | bucket | none (the bucket check) | `allowed` |
   | `s3:ListBucket` | bucket | `etcd` (reconciliation) | `allowed` |
   | `s3:ListBucket` | bucket | `etcd/etcd-snapshot-s4-k3s01` (retention) | `allowed` |
   | `s3:ListBucket` | bucket | `recovery/` | `allowed` (accepted in D2) |
   | `s3:ListBucketVersions` | bucket | none | denied |
   | `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` | `etcd/x` | n/a | `allowed` |
   | `s3:GetObject`, `s3:PutObject` | `recovery/x`, `evidence/x` | n/a | denied |
   | `s3:DeleteObjectVersion` | `etcd/x` | n/a | denied |
   | `s3:PutBucketPolicy`, `s3:PutLifecycleConfiguration` | bucket | n/a | denied |

   A result other than the expected one stops Stage 4, and the change is reviewed again.

The MinIO rehearsals (S4-2 and S4-3) show K3s's behavior, but MinIO may not model `StringLikeIfExists` exactly as AWS IAM does. This simulation is the first AWS-side check of D2, and it needs no access key.

## Creating the access key (S4-6)

1. Create a private directory on the workstation tmpfs. `XDG_RUNTIME_DIR` is a per-user tmpfs on the workstation; confirm it:

   ```bash
   set +x
   umask 077
   [ "$(stat -f -c %T "$XDG_RUNTIME_DIR")" = tmpfs ] || echo "not tmpfs: stop"
   keydir="$(mktemp -d "$XDG_RUNTIME_DIR/etcd-s3.XXXXXX")"
   ```

2. In an administrator SSO session, create the key straight into a `0600` file. Nothing reaches the terminal:

   ```bash
   aws iam create-access-key --user-name home-cluster-etcd-backup --output json \
     >"$keydir/etcd-key.json" 2>"$keydir/aws.err"; echo "rc=$?"
   chmod 0600 "$keydir/etcd-key.json"
   ```

   On a nonzero exit, record only the exit status. Read `aws.err` privately, then remove it.
3. Point the homelab-k3s playbooks at the file and at the bucket file. Only the paths go into the environment, never the values:

   ```bash
   export HOMELAB_ETCD_S3_KEY_FILE="$keydir/etcd-key.json"
   export HOMELAB_ETCD_S3_BUCKET_FILE="$HOME/.config/home-cluster/backup-bucket"
   ```

4. Run the homelab-k3s rollout, one server at a time, as its document describes.
5. **Remove the key file and its directory** once all three servers have been configured and restarted:

   ```bash
   rm -f -- "$keydir/etcd-key.json" "$keydir/aws.err"; rmdir -- "$keydir"
   unset HOMELAB_ETCD_S3_KEY_FILE HOMELAB_ETCD_S3_BUCKET_FILE
   ```

**The key stays on the servers.** Each server's drop-in, `/etc/rancher/k3s/config.yaml.d/30-etcd-s3.yaml`, holds it persistently, readable only by root, until a rotation replaces it. That is the one place the key is kept. It is not recovery material: after a disaster, a new key is issued.

## Rotation (every 90 days, or at once after suspected exposure)

1. Create the second key exactly as above, into a new tmpfs directory.
2. Run the homelab-k3s configuration on each server in turn. Each run writes the new drop-in and proves the new key with an on-demand upload before the server restarts; CLI saves read the drop-in on every run.
3. Restart the servers one at a time with the homelab-k3s restart playbook. Scheduled snapshots use a new key only after a restart.
4. **Only after all three servers have restarted**, deactivate the old key. Watch one full schedule cycle (12 hours) for uploads from every server.
5. Delete the old key. Remove the tmpfs copy of the new key.

The key's age is checked monthly from the IAM credential report, in a routine session, and recorded without key identifiers.

## Revocation

In order of speed:

1. Deactivate the key. Uploads fail; K3s keeps taking local snapshots and records the failures.
2. If the identity itself is suspect, attach an explicit deny-all inline policy to it.
3. Issue a replacement through the rotation procedure.
4. Follow the leaked-secret procedure in [SECURITY.md](../../SECURITY.md).

The revoked key is still in each server's drop-in until the rotation replaces it.

## Weekly freshness check (routine permission set)

Until external alert delivery exists, a routine session lists `etcd/` weekly and records, **per server, by count and age only**:

- the number of current objects whose keys start with `etcd/etcd-snapshot-s4-<host>-`, which must be 1 to 5;
- the age of the newest of them, which must be under 14 hours;
- the number of keys under `etcd/` that start with no approved base, which must be 0.

Approved bases are `etcd-snapshot-s4-<host>`, `on-demand-s4-<host>` and `stage3-`, plus `.metadata/` copies of them. The listing reads only key names and `LastModified`. It never reads object metadata, ETags, version IDs or object content, and it never prints a key name.

## Integrity

**An ETag is not an integrity check.** For a multipart upload it is not a digest of the object, and for some encryption modes it is not one even for a single part. Integrity is checked only by comparing the content of a downloaded object with the node's local snapshot, by exit status, never by printing a digest or size. No comparison method is approved for live use until the S4-2 rehearsal records one. Until then, any integrity check fails closed, and so does any unknown or unsupported remote-checksum behavior.

## What this runbook does not do

- It does not restore. Track A restores are in the [rehearsal tracks](../design/backup-disaster-recovery.md#rehearsal-tracks) and gate S4-7.
- It does not change the Velero identity or any other prefix.
- It does not retire the pre-Stage-4 local snapshots, which is a separate decision.
