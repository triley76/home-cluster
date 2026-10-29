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
RUNBOOK = "docs/runbooks/encrypted-recovery-material.md"
# The first lines of the scoped workstation and k3s01 cleanups. Mutations put back the
# earlier wildcard cleanups, which also removed ciphertexts retained from earlier runs.
WORKSTATION_CLEANUP = 'bash scripts/recovery-material.sh cleanup --dir "$run" \\\n'
HOST_CLEANUP = "bash ~/hc-recovery/scripts/recovery-material.sh cleanup --dir ~/hc-recovery/out \\\n"
# The workstation run cleanup waits for both verified offline copies.
TMPFS_REMOVED = '   test ! -e "$inv" && echo "inventory tmpfs: removed"\n'
EARLY_CLEANUP = '   bash scripts/recovery-material.sh cleanup --dir "$run" --remove recovery-inventory.age\n'
OFFLINE_GATE = "### Workstation run cleanup (after both offline copies)\n"
GATE_BOTH = "until Recovery A and Recovery B have both verified the exact-version downloaded inventory ciphertext"
GATE_PENDING = "If either device is pending or unavailable, keep the entire run directory"
GATE_PARTIAL = "do not remove any file from it, even one unrelated to the pending copy"
GATE_NO_MOVE = "do not move or copy its inventory ciphertext into `~/hc-recovery`"
OFFLINE_STOP = "an offline copy is pending or unverified when the workstation run cleanup is due. This stop is mandatory"
LOCK_STEP = "3. Lock the device (`manage-bde -lock <drive>:`)"
OFFLINE_SOURCE = "run-<YYYY-MM-DD>\\recovery-inventory.downloaded.age'"
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
# A synthetic 32-byte secretbox key in base64, as K3s writes it in encryption-config.json.
FAKE_ENC_KEY = ("Qm9n" * 11)[:43] + "="
FAKE_ENC_JSON = '{"secretbox":{"keys":[{"name":"k","sec' + 'ret":"' + FAKE_ENC_KEY + '"}]}}'
FAKE_ENC_YAML = "sec" + "ret: " + FAKE_ENC_KEY
ENC_ROW = "| K3s secrets-encryption configuration | Decryption comparison | `<YYYY-MM-DD, MATCH, DIFFER or ERROR>` |\n"
TOKEN_ROW = "| K3s server token | Ciphertext SHA-256 | `<ciphertext SHA-256>` |\n"
GRAFANA_ROW = "| Grafana admin credential | Last verification | `<YYYY-MM-DD, cmp -s result>` |\n"
INVENTORY_ROW = "| Previous inventory object | `<recovery/recovery-inventory/YYYY-MM-DD.age, or none>` |\n"


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
    "encryption-config-key-json": (append("docs/runbooks/encrypted-recovery-material.md", f"\n{FAKE_ENC_JSON}\n"), "encryption-config-key", FAKE_ENC_KEY),
    "encryption-config-key-yaml": (append("README.md", f"\n    {FAKE_ENC_YAML}\n"), "encryption-config-key", FAKE_ENC_KEY),
    "encryption-config-key-in-script": (append("scripts/validation-env.sh", f"\n# {FAKE_ENC_JSON}\n"), "encryption-config-key", FAKE_ENC_KEY),
    "encryption-config-file-name": (write("docs/encryption-config.json", b"{}\n"), "secret-file-name", "never-printed"),
    "encryption-config-backup-name": (write("backup/encryption-config-2026-10-27.json", b"{}\n"), "secret-file-name", "never-printed"),
    "template-encryption-config-value": (replace(TEMPLATE, "`<ciphertext size in bytes>` |", "`512` |"), "inventory-template-value", "never-printed"),
    "template-encryption-config-result": (replace(TEMPLATE, "`<YYYY-MM-DD, MATCH, DIFFER or ERROR>` |", "`2026-10-27, MATCH` |"), "inventory-template-value", "2026-10-27"),
    "template-encryption-config-row-missing": (replace(TEMPLATE, ENC_ROW, ""), "inventory-template-row-missing", "never-printed"),
    "template-token-row-missing": (replace(TEMPLATE, TOKEN_ROW, ""), "inventory-template-row-missing", "never-printed"),
    "template-grafana-row-missing": (replace(TEMPLATE, GRAFANA_ROW, ""), "inventory-template-row-missing", "never-printed"),
    "template-inventory-row-missing": (replace(TEMPLATE, INVENTORY_ROW, ""), "inventory-template-row-missing", "never-printed"),
    "template-plaintext-hash-field": (append(TEMPLATE, "| K3s secrets-encryption configuration | Plaintext SHA-256 | `<hash>` |\n"), "inventory-template-forbidden-field", "never-printed"),
    "template-key-name-field": (append(TEMPLATE, "| K3s secrets-encryption configuration | Key name | `<name>` |\n"), "inventory-template-forbidden-field", "never-printed"),
    "template-plaintext-size-field": (append(TEMPLATE, "| K3s server token | Plain size | `<bytes>` |\n"), "inventory-template-forbidden-field", "never-printed"),
    "runbook-wildcard-cleanup": (replace(RUNBOOK, WORKSTATION_CLEANUP, "   rm -f -- ~/hc-recovery/*.age\n   true \\\n"), "runbook-broad-delete", "never-printed"),
    "runbook-host-wildcard-cleanup": (replace(RUNBOOK, HOST_CLEANUP, "rm -f -- ~/hc-recovery/out/identity-archive.age ~/hc-recovery/out/*.age\ntrue \\\n"), "runbook-broad-delete", "never-printed"),
    "runbook-recursive-delete": (append(RUNBOOK, "\nrm -rf -- ~/hc-recovery\n"), "runbook-broad-delete", "never-printed"),
    "runbook-recursive-long-option": (append(RUNBOOK, "\nrm --recursive --force -- ~/hc-recovery\n"), "runbook-broad-delete", "never-printed"),
    "runbook-scoped-cleanup-removed": (replace(RUNBOOK, WORKSTATION_CLEANUP, "true \\\n"), "runbook-scoped-cleanup-missing", "never-printed"),
    "runbook-cleanup-in-inventory-step": (replace(RUNBOOK, TMPFS_REMOVED, TMPFS_REMOVED + EARLY_CLEANUP), "runbook-cleanup-before-offline-copies", "never-printed"),
    "runbook-cleanup-outside-gate": (append(RUNBOOK, "\n" + EARLY_CLEANUP), "runbook-cleanup-before-offline-copies", "never-printed"),
    "runbook-gate-before-copy-steps": (replace(RUNBOOK, LOCK_STEP, "3. Disconnect the device"), "runbook-cleanup-before-offline-copies", "never-printed"),
    "runbook-gate-outside-offline-section": (replace(RUNBOOK, OFFLINE_GATE, "## Later\n\n" + OFFLINE_GATE), "runbook-offline-gate-missing", "never-printed"),
    "runbook-gate-heading-removed": (replace(RUNBOOK, OFFLINE_GATE, "### Workstation run cleanup\n"), "runbook-offline-gate-missing", "never-printed"),
    "runbook-gate-one-device-only": (replace(RUNBOOK, GATE_BOTH, "until Recovery A has verified the exact-version downloaded inventory ciphertext"), "runbook-offline-gate-missing", "never-printed"),
    "runbook-pending-retention-removed": (replace(RUNBOOK, GATE_PENDING, "If a device is pending, clean up the rest of the run directory"), "runbook-offline-gate-missing", "never-printed"),
    "runbook-partial-cleanup-allowed": (replace(RUNBOOK, GATE_PARTIAL, "remove the files unrelated to the pending copy"), "runbook-offline-gate-missing", "never-printed"),
    "runbook-move-to-retained-allowed": (replace(RUNBOOK, GATE_NO_MOVE, "move its inventory ciphertext into `~/hc-recovery`"), "runbook-offline-gate-missing", "never-printed"),
    "runbook-offline-stop-removed": (replace(RUNBOOK, OFFLINE_STOP, "an offline copy is pending"), "runbook-offline-stop-missing", "never-printed"),
    "runbook-offline-source-original": (replace(RUNBOOK, OFFLINE_SOURCE, "run-<YYYY-MM-DD>\\recovery-inventory.age'"), "runbook-offline-source", "never-printed"),
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
        for value, rule in (
            (FAKE_SECRET_KEY, "age-secret-key"),
            (FAKE_ACCOUNT, "aws-account-id"),
            (FAKE_ACCESS_KEY, "aws-access-key-id"),
            (FAKE_ENC_JSON, "encryption-config-key"),
            (f"| K3s secrets-encryption configuration | Source check | {FAKE_ENC_YAML} |", "encryption-config-key"),
        ):
            evidence.write_text(f"line\n{value}\n", encoding="utf-8")
            dirty = run(base, "--scan", str(evidence))
            assert dirty.returncode == 1 and f":2: {rule}\n" in dirty.stderr, f"--scan missed {rule}"
            assert value not in dirty.stdout + dirty.stderr, f"--scan printed the {rule} value"
            assert FAKE_ENC_KEY not in dirty.stdout + dirty.stderr, "--scan printed the encryption key"
        # A filled encryption-configuration row with metadata only is accepted.
        filled = Path(temp, "filled-inventory.md")
        filled.write_text(
            "| K3s secrets-encryption configuration | Object key | `recovery/encryption-config/2026-10-27.age` |\n"
            "| K3s secrets-encryption configuration | Ciphertext SHA-256 | `" + "ab" * 32 + "` |\n"
            "| K3s secrets-encryption configuration | Decryption comparison | `2026-10-27, MATCH` |\n"
            "| K3s secrets-encryption configuration | Recovery-copy status | `verified` |\n",
            encoding="utf-8",
        )
        ok = run(base, "--scan", str(filled))
        assert ok.returncode == 0, f"metadata-only inventory rows rejected:\n{ok.stderr}"

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
    print(f"Recovery-material scanner mutation tests passed: {len(CASES)} cases, plus recipient, --scan, filled-inventory and force-add checks")


if __name__ == "__main__":
    main()
