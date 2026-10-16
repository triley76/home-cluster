#!/usr/bin/env python3
"""Mutation tests for the fail-closed recovery-material scanner.

Each case copies the scanned files into a temporary directory, applies one
mutation and requires the scanner to fail with the expected rule name, without
printing the injected value. Every secret-shaped fixture is assembled at runtime
from fragments, so this file does not itself contain one.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCANNER = "scripts/validate-recovery-material.py"
RECIPIENT = "recovery/home-cluster-recovery-recipient.txt"
TEMPLATE = "docs/runbooks/recovery-material-inventory-template.md"
HELPER = "scripts/recovery-material.sh"

BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
FAKE_RECIPIENT = "age1" + (BECH32 * 2)[:58]
FAKE_SECRET_KEY = "AGE-SECRET" + "-KEY-1" + (BECH32.upper() * 2)[:58]
FAKE_K3S_TOKEN = "K10" + "ab" * 32 + "::" + "server" + ":" + "0f" * 16
FAKE_BARE_TOKEN = "server" + ":" + "c3" * 16
FAKE_ACCOUNT = "4242" + "4242" + "4242"
FAKE_ACCESS_KEY = "AK" + "IA" + "Q" * 16
FAKE_SECRET_ASSIGNMENT = "aws_secret_" + "access_key = " + "Ab1/" * 10
AGE_HEADER = "age-encryption.org" + "/v1\n-> X25519 x\ny\n--- z\n"


def scanned_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
    ).stdout.decode("utf-8")
    return [name for name in out.split("\0") if name and (ROOT / name).is_file()]


def run(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / SCANNER), "--root", str(root), *args],
        text=True,
        capture_output=True,
        check=False,
    )


def copy_tree(files: list[str], destination: Path) -> None:
    for name in files:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    # The test tree must start from a valid recipient without depending on the real one.
    (destination / RECIPIENT).write_bytes((FAKE_RECIPIENT + "\n").encode())


def append(path: str, text: str):
    def mutate(root: Path) -> None:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    return mutate


def write(path: str, data: bytes):
    def mutate(root: Path) -> None:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return mutate


def replace(path: str, old: str, new: str):
    def mutate(root: Path) -> None:
        target = root / path
        content = target.read_text(encoding="utf-8")
        assert old in content, f"mutation anchor missing in {path}: {old!r}"
        target.write_text(content.replace(old, new, 1), encoding="utf-8", newline="\n")
    return mutate


def remove(path: str):
    def mutate(root: Path) -> None:
        (root / path).unlink()
    return mutate


# name: (mutation, expected rule, injected value that must not be printed)
CASES = {
    "age-secret-key-in-doc": (append("docs/runbooks/encrypted-recovery-material.md", f"\n{FAKE_SECRET_KEY}\n"), "age-secret-key", FAKE_SECRET_KEY),
    "age-secret-key-in-script": (append("scripts/validation-env.sh", f"\n# {FAKE_SECRET_KEY}\n"), "age-secret-key", FAKE_SECRET_KEY),
    "k3s-full-token": (append("README.md", f"\ntoken: {FAKE_K3S_TOKEN}\n"), "k3s-token", FAKE_K3S_TOKEN),
    "k3s-bare-token": (append("docs/design/backup-disaster-recovery.md", f"\n{FAKE_BARE_TOKEN}\n"), "k3s-token", FAKE_BARE_TOKEN),
    "account-id": (append("aws/backup/README.md", f"\nAccount {FAKE_ACCOUNT}\n"), "aws-account-id", FAKE_ACCOUNT),
    "account-id-in-arn": (append("SECURITY.md", f"\narn:aws:iam::{FAKE_ACCOUNT}:user/x\n"), "aws-account-id", FAKE_ACCOUNT),
    "access-key-id": (append("scripts/validation-env.sh", f"\n# {FAKE_ACCESS_KEY}\n"), "aws-access-key-id", FAKE_ACCESS_KEY),
    "secret-access-key": (append("README.md", f"\n{FAKE_SECRET_ASSIGNMENT}\n"), "aws-secret-access-key", FAKE_SECRET_ASSIGNMENT),
    "ciphertext-file": (write("docs/notes.txt", AGE_HEADER.encode()), "age-ciphertext", "--- z"),
    "age-file-name": (write("docs/k3s-server-token-2026-10-20.age", b"x\n"), "secret-file-name", "never-printed"),
    "keygen-default-name": (write("keys.txt", b"x\n"), "secret-file-name", "never-printed"),
    "identity-file-name": (write("docs/home-cluster-identity.txt", b"x\n"), "secret-file-name", "never-printed"),
    "token-file-name": (write("backup/token", b"x\n"), "secret-file-name", "never-printed"),
    "grafana-credential-name": (write("grafana-admin", b"x\n"), "secret-file-name", "never-printed"),
    "aws-config-dir": (write(".aws/config", b"x\n"), "secret-file-name", "never-printed"),
    "filled-inventory-name": (write("docs/runbooks/recovery-material-inventory.md", b"x\n"), "secret-file-name", "never-printed"),
    "recipient-missing": (remove(RECIPIENT), "recipient-missing", FAKE_RECIPIENT),
    "recipient-crlf": (write(RECIPIENT, (FAKE_RECIPIENT + "\r\n").encode()), "recipient-format", FAKE_RECIPIENT),
    "recipient-two-lines": (write(RECIPIENT, (FAKE_RECIPIENT + "\n" + FAKE_RECIPIENT + "\n").encode()), "recipient-format", FAKE_RECIPIENT),
    "recipient-no-newline": (write(RECIPIENT, FAKE_RECIPIENT.encode()), "recipient-format", FAKE_RECIPIENT),
    "recipient-is-secret-key": (write(RECIPIENT, (FAKE_SECRET_KEY + "\n").encode()), "recipient-format", FAKE_SECRET_KEY),
    "recovery-extra-file": (write("recovery/notes.md", b"x\n"), "recovery-unexpected-file", "never-printed"),
    "template-filled-value": (replace(TEMPLATE, "`<YYYY-MM-DD>` |", "`2026-10-20` |"), "inventory-template-value", "2026-10-20"),
    "template-missing": (remove(TEMPLATE), "inventory-template-missing", "never-printed"),
    "helper-tracing": (replace(HELPER, "set -euo pipefail\n", "set -euo pipefail\nset -x\n"), "helper-tracing", "never-printed"),
    "helper-debug-flag": (replace(HELPER, "  version=\"$(age --version", "  aws --debug >/dev/null\n  version=\"$(age --version"), "helper-debug-flag", "never-printed"),
    "helper-plaintext-digest": (replace(HELPER, "  rm -f -- \"${work}/plain\"\n\n", "  sha256sum -- \"${work}/plain\"\n  rm -f -- \"${work}/plain\"\n\n"), "helper-plaintext-digest", "never-printed"),
    "helper-plaintext-output": (replace(HELPER, "  rm -f -- \"${work}/plain\"\n\n", "  cat -- \"${work}/plain\"\n  rm -f -- \"${work}/plain\"\n\n"), "helper-plaintext-output", "never-printed"),
}


def main() -> None:
    files = scanned_files()
    failures = []

    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp, "base")
        copy_tree(files, base)
        baseline = run(base)
        assert baseline.returncode == 0, f"baseline failed:\n{baseline.stderr}"

        good = run(base, "--check-recipient", str(base / RECIPIENT))
        assert good.returncode == 0 and good.stdout.strip() == "PASS", "valid recipient not accepted"
        assert FAKE_RECIPIENT not in good.stdout + good.stderr, "recipient value was printed"
        bad_path = Path(temp, "bad-recipient")
        bad_path.write_bytes((FAKE_RECIPIENT + "\r\n").encode())
        bad = run(base, "--check-recipient", str(bad_path))
        assert bad.returncode == 1 and bad.stdout.strip() == "FAIL", "CRLF recipient accepted"

        evidence = Path(temp, "evidence.txt")
        evidence.write_text("clean evidence line\n", encoding="utf-8")
        clean = run(base, "--scan", str(evidence))
        assert clean.returncode == 0, f"clean evidence rejected:\n{clean.stderr}"
        # --scan is content-only: a filled inventory's ignored file name is not a finding.
        inventory = Path(temp, "recovery-material-inventory.md")
        inventory.write_text("| Bucket | example |\n", encoding="utf-8")
        named = run(base, "--scan", str(inventory))
        assert named.returncode == 0, f"--scan applied file-name rules:\n{named.stderr}"
        missing = run(base, "--scan", str(Path(temp, "absent.txt")))
        assert missing.returncode == 1 and "not a file" in missing.stderr, "--scan accepted a missing file"
        for value, rule in ((FAKE_SECRET_KEY, "age-secret-key"), (FAKE_ACCOUNT, "aws-account-id"), (FAKE_ACCESS_KEY, "aws-access-key-id")):
            evidence.write_text(f"line\n{value}\n", encoding="utf-8")
            dirty = run(base, "--scan", str(evidence))
            assert dirty.returncode == 1 and f":2: {rule}\n" in dirty.stderr, f"--scan missed {rule}"
            assert value not in dirty.stdout + dirty.stderr, f"--scan printed the {rule} value"

    for name, (mutate, rule, value) in CASES.items():
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            copy_tree(files, root)
            mutate(root)
            result = run(root)
            output = result.stdout + result.stderr
            if result.returncode == 0:
                failures.append(f"{name}: mutation unexpectedly passed")
            elif f": {rule}\n" not in output:
                failures.append(f"{name}: expected rule {rule} not reported")
            if value in output:
                failures.append(f"{name}: matched value was printed")

    # A secret-named file force-added past .gitignore in a scratch Git repository
    # (never this repository) must still be reported, because staged files are scanned.
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        copy_tree(files, root)
        (root / ".gitignore").write_text("*.age\n", encoding="utf-8")
        (root / "forced.age").write_bytes(b"x\n")
        git = ["git", "-C", str(root), "-c", "core.autocrlf=false"]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "add", "-f", "forced.age"], check=True)
        result = run(root)
        if result.returncode == 0 or "forced.age:0: secret-file-name\n" not in result.stderr:
            failures.append("force-added: a force-added ignored file was not reported")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print(f"Recovery-material scanner mutation tests passed: {len(CASES)} cases, plus recipient, --scan and force-add checks")


if __name__ == "__main__":
    main()
