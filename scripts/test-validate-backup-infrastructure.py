#!/usr/bin/env python3
"""Mutation tests for the fail-closed Stage 1 validator."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-backup-infrastructure.py"
DESIGN = "docs/design/backup-disaster-recovery.md"


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
