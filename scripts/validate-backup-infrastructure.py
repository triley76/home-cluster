#!/usr/bin/env python3
"""Fail-closed static checks for the Stage 1 CloudFormation templates and the Stage 4 design decisions."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMBER = ROOT / "aws/backup/member-account.yaml"
MANAGEMENT = ROOT / "aws/backup/management-account.yaml"
README = ROOT / "aws/backup/README.md"
DESIGN = ROOT / "docs/design/backup-disaster-recovery.md"
FILES = (MEMBER, MANAGEMENT, README, DESIGN)

# Approved S4-0 decisions that the design must keep stating.
STAGE4_REQUIRED = (
    "## Stage 4: etcd off-cluster uploads (S4-0 design)",
    "| `etcd-snapshot-name` | `etcd-snapshot-s4-{{ inventory_hostname }}`, rendered per server |",
    "| `etcd-snapshot-retention` | `5` (local, per server) |",
    "| `etcd-s3-folder` | `etcd`, shared by all three servers |",
    "| `etcd-s3-retention` | `5` (in S3, per server) |",
    "| `etcd-snapshot-compress` | `false`.",
    "`--name on-demand-s4-<host>`",
    "A CLI save without an explicit `--name` is refused by the tooling",
    "a missing, default or differently prefixed name is refused before any K3s restart and before any snapshot is created",
    '"Condition": { "StringLikeIfExists": { "s3:prefix": ["etcd", "etcd/*"] } }',
    "The etcd identity can list every object **key name** in the backup bucket",
    "It still cannot read, write or delete any object outside `etcd/*`",
    "counts exact occurrences of the marker's byte sequence",
    "Stage 4 is not complete until Track A restores a **real AWS object from `etcd/`**",
    "a weekly manual check runs with the routine permission set",
    "1. **S4-0: research and design.** This section. Nothing implemented.",
)
# S4-1 (D2, Option 1): the etcd identity's whole policy, exactly. The prefix-less
# bucket check and the reconcile listing (prefix etcd) need IfExists and both
# prefixes; objects stay limited to etcd/*. Any widening is a design amendment.
ETCD_POLICY = """\
      Policies:
        - PolicyName: home-cluster-etcd-prefix
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: ListEtcdPrefix
                Effect: Allow
                Action: s3:ListBucket
                Resource: !GetAtt BackupBucket.Arn
                Condition:
                  StringLikeIfExists:
                    s3:prefix:
                      - etcd
                      - etcd/*
              - Sid: ManageEtcdObjects
                Effect: Allow
                Action:
                  - s3:AbortMultipartUpload
                  - s3:DeleteObject
                  - s3:GetObject
                  - s3:ListMultipartUploadParts
                  - s3:PutObject
                Resource: !Sub '${BackupBucket.Arn}/etcd/*'
"""
# Velero keeps the Stage 1 condition until Stage 5 assesses it.
VELERO_LIST = """\
              - Sid: ListVolumesPrefix
                Effect: Allow
                Action: s3:ListBucket
                Resource: !GetAtt BackupBucket.Arn
                Condition:
                  StringLike:
                    s3:prefix:
                      - volumes/*
              - Sid: ManageVolumeObjects
"""
ETCD_DENY = """\
          - Sid: DenyEtcdUserOutsideEtcd
            Effect: Deny
            Principal:
              AWS: !GetAtt EtcdBackupUser.Arn
            Action:
              - s3:AbortMultipartUpload
              - s3:DeleteObject
              - s3:GetObject
              - s3:ListMultipartUploadParts
              - s3:PutObject
            NotResource: !Sub '${BackupBucket.Arn}/etcd/*'
"""
# The design must keep the S4-1 state and the corrected action list.
STAGE4_S41_REQUIRED = (
    "**Status: S4-1 implemented (static tests only); the template change is not deployed.**",
    "`s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` on `etcd/*`",
    "Until gate 9, the template in this repository differs from the deployed stack",
)
# Rejected or superseded choices that must not return.
STAGE4_FORBIDDEN = (
    "etcd-snapshot-{{ inventory_hostname }}",
    "`etcd-s3-retention` | `15`",
    "etcd-s3-config-secret:",
    "encrypted Ansible variables",
    "credentials from encrypted variables",
    "enable it (recommended) and rehearse a compressed restore",
)


def require(text: str, token: str, path: Path) -> None:
    if token not in text:
        raise AssertionError(f"{path}: missing required token: {token}")


def resource_block(member: str, name: str) -> str:
    match = re.search(rf"^  {name}:\n(.*?)(?=^  [A-Za-z]|^[A-Za-z]|\Z)", member, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"{MEMBER}: resource {name} not found")
    return match.group(1)


def check_stage4_identity(member: str) -> None:
    etcd = resource_block(member, "EtcdBackupUser")
    if not etcd.rstrip("\n").endswith(ETCD_POLICY.rstrip("\n")) or etcd.count("- Sid:") != 2:
        raise AssertionError(f"{MEMBER}: the etcd identity policy is not exactly the approved S4-1 policy")
    if VELERO_LIST not in resource_block(member, "VeleroBackupUser"):
        raise AssertionError(f"{MEMBER}: the Velero listing condition changed")
    if ETCD_DENY not in resource_block(member, "BackupBucketPolicy"):
        raise AssertionError(f"{MEMBER}: the deny for the etcd identity outside etcd/* is missing or changed")
    if member.count("IfExists") != 1:
        raise AssertionError(f"{MEMBER}: IfExists is approved only for the etcd listing condition")


def check_stage4_design(text: str) -> None:
    for token in STAGE4_REQUIRED + STAGE4_S41_REQUIRED:
        require(text, token, DESIGN)
    for forbidden in STAGE4_FORBIDDEN:
        if forbidden in text:
            raise AssertionError(f"{DESIGN}: rejected Stage 4 choice present: {forbidden}")


def main() -> int:
    texts = {path: path.read_text(encoding="utf-8") for path in FILES}
    combined = "\n".join(texts.values())

    # Reject real account IDs and credentials without rejecting the parameter regex.
    scrubbed = combined.replace("[0-9]{12}", "").replace("\\d{12}", "")
    if re.search(r"(?<![0-9])[0-9]{12}(?![0-9])", scrubbed):
        raise AssertionError("AWS account ID detected in Stage 1 files")
    if re.search(r"AKIA[0-9A-Z]{16}", combined):
        raise AssertionError("AWS access-key identifier detected")
    if re.search(r"(?i)(access|secret)[_-]?key\s*[:=]\s*[^$<{\s]", combined):
        raise AssertionError("possible literal AWS credential detected")

    member = texts[MEMBER]
    for token in (
        "DeletionPolicy: Retain",
        "UpdateReplacePolicy: Retain",
        "SSEAlgorithm: AES256",
        "ObjectOwnership: BucketOwnerEnforced",
        "BlockPublicAcls: true",
        "BlockPublicPolicy: true",
        "IgnorePublicAcls: true",
        "RestrictPublicBuckets: true",
        "VersioningConfiguration:",
        "Status: Enabled",
        "DaysAfterInitiation: 1",
        "NoncurrentDays: 14",
        "NoncurrentDays: 7",
        "NoncurrentDays: 90",
        "ExpirationInDays: 365",
        "NoncurrentDays: 30",
        "UserName: home-cluster-etcd-backup",
        "UserName: home-cluster-velero",
        "Sid: DenyInsecureTransport",
        "Sid: DenyOldTLS",
        "Sid: DenySSEC",
        "Sid: DenyBucketDeletion",
        "s3:DeleteObjectVersion",
        "s3:BypassGovernanceRetention",
        "s3:PutBucketObjectLockConfiguration",
        "s3:PutBucketOwnershipControls",
        "s3:PutEncryptionConfiguration",
    ):
        require(member, token, MEMBER)
    for forbidden in ("AWS::IAM::AccessKey", "LoginProfile:", "aws:kms", "SSEAlgorithm: aws:kms"):
        if forbidden in member:
            raise AssertionError(f"{MEMBER}: forbidden token: {forbidden}")
    check_stage4_identity(member)

    management = texts[MANAGEMENT]
    for token in (
        "Type: AWS::SSO::PermissionSet",
        "Type: AWS::SSO::Assignment",
        "Name: HomeClusterBackupOperator",
        "SessionDuration: PT2H",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "iam:GenerateCredentialReport",
        "iam:GetCredentialReport",
    ):
        require(management, token, MANAGEMENT)
    for forbidden in (
        "AdministratorAccess",
        "s3:DeleteBucket",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutLifecycleConfiguration",
    ):
        if forbidden in management:
            raise AssertionError(f"{MANAGEMENT}: routine operator is over-privileged: {forbidden}")

    check_stage4_design(texts[DESIGN])

    print("Stage 1 backup infrastructure and Stage 4 design checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
