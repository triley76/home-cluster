#!/usr/bin/env python3
"""Fail-closed static checks for the Stage 1 CloudFormation templates."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMBER = ROOT / "aws/backup/member-account.yaml"
MANAGEMENT = ROOT / "aws/backup/management-account.yaml"
README = ROOT / "aws/backup/README.md"
FILES = (MEMBER, MANAGEMENT, README)


def require(text: str, token: str, path: Path) -> None:
    if token not in text:
        raise AssertionError(f"{path}: missing required token: {token}")


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

    print("Stage 1 backup infrastructure checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
