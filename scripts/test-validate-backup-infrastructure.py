#!/usr/bin/env python3
"""Mutation tests for the fail-closed Stage 1 validator."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-backup-infrastructure.py"
DESIGN = "docs/design/backup-disaster-recovery.md"
MEMBER = "aws/backup/member-account.yaml"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(root / "scripts/validate-backup-infrastructure.py")],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> None:
    baseline = run(ROOT)
    assert baseline.returncode == 0, baseline.stderr

    mutations = {
        "account-id": ("aws/backup/README.md", "<random-suffix>", "1234567" + "89012"),
        "access-key-resource": ("aws/backup/member-account.yaml", "Outputs:\n", "  BadKey:\n    Type: AWS::IAM::AccessKey\nOutputs:\n"),
        "disable-encryption": ("aws/backup/member-account.yaml", "SSEAlgorithm: AES256", "SSEAlgorithm: aws:kms"),
        "remove-tls-deny": ("aws/backup/member-account.yaml", "Sid: DenyOldTLS", "Sid: MissingOldTLSDeny"),
        "operator-admin": ("aws/backup/management-account.yaml", "SessionDuration: PT2H", "ManagedPolicies:\n        - AdministratorAccess\n      SessionDuration: PT2H"),
        "stage4-prefix-matching-name": (DESIGN, "`etcd-snapshot-s4-{{ inventory_hostname }}`", "`etcd-snapshot-{{ inventory_hostname }}`"),
        "stage4-shared-retention": (DESIGN, "| `etcd-s3-retention` | `5` (in S3, per server) |", "| `etcd-s3-retention` | `15` (in S3, per server) |"),
        "stage4-compression-on": (DESIGN, "| `etcd-snapshot-compress` | `false`.", "| `etcd-snapshot-compress` | `true`."),
        "stage4-config-secret": (DESIGN, "| `etcd-s3` | `true` |", "| `etcd-s3` | `true`; `etcd-s3-config-secret: etcd-s3` |"),
        "stage4-encrypted-variables": (DESIGN, "rendered by homelab-k3s from a `0600` file in a private workstation tmpfs", "written by homelab-k3s from encrypted Ansible variables"),
        "stage4-no-default-name-guard": (DESIGN, "a missing, default or differently prefixed name is refused", "a missing name is reported"),
        "stage4-unscoped-listing-silent": (DESIGN, "The etcd identity can list every object **key name** in the backup bucket", "The etcd identity lists only its own prefix"),
        "stage4-text-marker-search": (DESIGN, "counts exact occurrences of the marker's byte sequence", "counts its base64 rendering"),
        "stage4-completion-without-aws-restore": (DESIGN, "Stage 4 is not complete until Track A restores a **real AWS object from `etcd/`**", "Stage 4 is complete once uploads appear under `etcd/`"),
        "s41-condition-reverted": (MEMBER, "StringLikeIfExists:\n                    s3:prefix:\n                      - etcd\n", "StringLike:\n                    s3:prefix:\n                      - etcd\n"),
        "s41-reconcile-prefix-dropped": (MEMBER, "                      - etcd\n                      - etcd/*\n", "                      - etcd/*\n"),
        "s41-wildcard-prefix": (MEMBER, "                      - etcd/*\n              - Sid: ManageEtcdObjects", "                      - etcd/*\n                      - '*'\n              - Sid: ManageEtcdObjects"),
        "s41-recovery-prefix": (MEMBER, "                      - etcd/*\n              - Sid: ManageEtcdObjects", "                      - etcd/*\n                      - recovery/*\n              - Sid: ManageEtcdObjects"),
        "s41-velero-ifexists": (MEMBER, "                  StringLike:\n                    s3:prefix:\n                      - volumes/*", "                  StringLikeIfExists:\n                    s3:prefix:\n                      - volumes/*"),
        "s41-object-resource-widened": (MEMBER, "Resource: !Sub '${BackupBucket.Arn}/etcd/*'\n\n  VeleroBackupUser", "Resource: !Sub '${BackupBucket.Arn}/*'\n\n  VeleroBackupUser"),
        "s41-get-object-version": (MEMBER, "                  - s3:GetObject\n                  - s3:ListMultipartUploadParts", "                  - s3:GetObject\n                  - s3:GetObjectVersion\n                  - s3:ListMultipartUploadParts"),
        "s41-list-bucket-versions": (MEMBER, "                Action: s3:ListBucket\n                Resource: !GetAtt BackupBucket.Arn\n                Condition:\n                  StringLikeIfExists", "                Action:\n                  - s3:ListBucket\n                  - s3:ListBucketVersions\n                Resource: !GetAtt BackupBucket.Arn\n                Condition:\n                  StringLikeIfExists"),
        "s41-extra-etcd-statement": (MEMBER, "                Resource: !Sub '${BackupBucket.Arn}/etcd/*'\n\n  VeleroBackupUser", "                Resource: !Sub '${BackupBucket.Arn}/etcd/*'\n              - Sid: ExtraEtcdGrant\n                Effect: Allow\n                Action: s3:GetBucketLocation\n                Resource: !GetAtt BackupBucket.Arn\n\n  VeleroBackupUser"),
        "s41-etcd-deny-widened": (MEMBER, "            NotResource: !Sub '${BackupBucket.Arn}/etcd/*'", "            NotResource: !Sub '${BackupBucket.Arn}/*'"),
        "s41-design-status": (DESIGN, "**Status: S4-1 implemented (static tests only); the template change is not deployed.**", "**Status: S4-1 deployed.**"),
        "s41-design-action-list": (DESIGN, "`s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` on `etcd/*`", "`s3:AbortMultipartUpload` on `etcd/*`"),
        "s41-design-deployed-note": (DESIGN, "Until gate 9, the template in this repository differs from the deployed stack", "The template matches the deployed stack"),
    }

    for name, (target_name, old, new) in mutations.items():
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp)
            for relative in (
                "aws/backup/member-account.yaml",
                "aws/backup/management-account.yaml",
                "aws/backup/README.md",
                DESIGN,
                "scripts/validate-backup-infrastructure.py",
            ):
                target = copy / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((ROOT / relative).read_text(encoding="utf-8"), encoding="utf-8")

            target = copy / target_name
            content = target.read_text(encoding="utf-8")
            assert old in content, f"mutation anchor missing: {name}"
            target.write_text(content.replace(old, new, 1), encoding="utf-8")
            result = run(copy)
            assert result.returncode != 0, f"mutation unexpectedly passed: {name}"

    print(f"Validator mutation tests passed: {len(mutations)}")


if __name__ == "__main__":
    main()
