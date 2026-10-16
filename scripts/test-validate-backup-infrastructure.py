#!/usr/bin/env python3
"""Mutation tests for the fail-closed Stage 1 validator."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-backup-infrastructure.py"


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
    }

    for name, (target_name, old, new) in mutations.items():
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp)
            for relative in (
                "aws/backup/member-account.yaml",
                "aws/backup/management-account.yaml",
                "aws/backup/README.md",
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
