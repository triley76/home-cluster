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
# Updating an existing inventory.
UPDATE_HEADING = "### Updating an existing inventory\n"
UPDATE_DECRYPT = 'recovery-material.sh decrypt-inventory --inventory-dir "$inv"'
UPDATE_KEEPALIVE = "   pgrep -fx 'sleep 14400'                         # the keep-alive (prerequisite 3) must still be running\n"
UPDATE_SWAP = "   swapon --show                                   # must print nothing\n"
UPDATE_TMPFS = '   findmnt -no FSTYPE --mountpoint "$inv"          # must print: tmpfs\n'
UPDATE_TAIL = "   stat -c '%a %U' \"$inv\"                          # must print: 700 <your user>\n   umask 077\n"
SAFE_VIM = "   vim -n -i NONE -c 'set nobackup nowritebackup noundofile' \"$inv/recovery-material-inventory.md\"\n"
UPDATE_VALIDATE = (
    '   python3 scripts/validate-recovery-material.py --check-inventory "$inv/recovery-material-inventory.md" \\\n'
    "     --previous-key recovery/recovery-inventory/<previous YYYY-MM-DD>.age \\\n"
    "     --previous-sha256 <recorded previous inventory ciphertext SHA-256>\n"
)
UPDATE_PREVIOUS_SHA = (
    "     --previous-key recovery/recovery-inventory/<previous YYYY-MM-DD>.age \\\n"
    "     --previous-sha256 <recorded previous inventory ciphertext SHA-256>\n"
)
# Recovery A and B: a new, timestamped name, created with CreateNew.
OFFLINE_DESTINATION = "recovery-inventory-<YYYY-MM-DD>-<YYYYMMDDTHHMMSSZ>.age'"
OFFLINE_CREATE = "     $out = [IO.File]::Open($dst, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)\n"
# The interim manual p2 snapshot copy.
P2_SECTION = "## The interim manual p2 snapshot copy (stage3-p2-snapshot)\n"
P2_NOT_STAGE4 = "**It is not a Stage 4 upload.**"
P2_ROW = "| Interim manual p2 snapshot copy | Source check | "
PREVIOUS_SHA_ROW = "| Previous inventory ciphertext SHA-256 | `<ciphertext SHA-256 of the inventory version being replaced, or none>` |\n"
SNAPSHOT_DIGEST_BODY = "  [[ \"$(sha256sum -- \"$1\" | cut -d' ' -f1)\" == \"$2\" ]]\n"
S3_HELPER = "scripts/recovery-material-s3.sh"
UPDATE_REMOVE = '   rm -f -- "$inv/previous-inventory.md"\n'
UPDATE_REMOVE_STEP = "5. **Remove the previous plaintext before encrypting:**"
UPDATE_CONTINUE = "6. **Only then continue with step 3**"
GATE_KEEP_PRIOR = 'also pass `--keep "$prior"`'
PREVIOUS_KEY = "recovery/recovery-inventory/2026-10-29.age"
PREVIOUS_SHA = "c3" * 32
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
    "update-decrypt-outside-tmpfs": (replace(RUNBOOK, UPDATE_DECRYPT, 'recovery-material.sh decrypt-inventory --inventory-dir ~/hc-recovery'), "runbook-decrypt-outside-tmpfs", "never-printed"),
    "update-decrypt-outside-section": (append(RUNBOOK, '\nbash scripts/recovery-material.sh decrypt-inventory --inventory-dir "$inv" --ciphertext "$prior"\n'), "runbook-decrypt-outside-tmpfs", "never-printed"),
    "update-raw-age-decrypt": (append(RUNBOOK, '\nage -d -i "$archive" -o ~/previous-inventory.md -- "$prior"\n'), "runbook-decrypt-outside-tmpfs", "never-printed"),
    "update-raw-age-long-decrypt": (append(RUNBOOK, '\nage --decrypt -i "$archive" -- "$prior" > "$inv/previous-inventory.md"\n'), "runbook-decrypt-outside-tmpfs", "never-printed"),
    "update-keepalive-gate-removed": (replace(RUNBOOK, UPDATE_KEEPALIVE, ""), "runbook-update-gates-missing", "never-printed"),
    "update-swap-gate-removed": (replace(RUNBOOK, UPDATE_SWAP + UPDATE_TMPFS + UPDATE_TAIL, UPDATE_TMPFS + UPDATE_TAIL), "runbook-update-gates-missing", "never-printed"),
    "update-tmpfs-gate-removed": (replace(RUNBOOK, UPDATE_TMPFS + UPDATE_TAIL, UPDATE_TAIL), "runbook-update-gates-missing", "never-printed"),
    "update-plaintext-cat": (append(RUNBOOK, '\ncat -- "$inv/previous-inventory.md"\n'), "runbook-plaintext-output", "never-printed"),
    "update-plaintext-grep": (append(RUNBOOK, '\ngrep -n Bucket "$inv/recovery-material-inventory.md"\n'), "runbook-plaintext-output", "never-printed"),
    "update-plaintext-other-editor": (append(RUNBOOK, '\nnano "$inv/previous-inventory.md"\n'), "runbook-plaintext-output", "never-printed"),
    "update-unsafe-vim": (replace(RUNBOOK, SAFE_VIM, '   vim "$inv/recovery-material-inventory.md"\n'), "runbook-unsafe-editor", "never-printed"),
    "update-validation-removed": (replace(RUNBOOK, UPDATE_VALIDATE, ""), "runbook-update-validation-missing", "never-printed"),
    "update-previous-plaintext-kept": (replace(RUNBOOK, UPDATE_REMOVE, ""), "runbook-update-previous-not-removed", "never-printed"),
    "update-encrypt-before-removal": (replace(RUNBOOK, UPDATE_REMOVE_STEP, "5. **Only then continue with step 3**; afterwards remove the previous plaintext:"), "runbook-update-previous-not-removed", "never-printed"),
    "update-prior-overwritten": (append(RUNBOOK, '\ncp -- "$run/recovery-inventory.age" "$prior"\n'), "runbook-update-prior-unprotected", "never-printed"),
    "update-prior-deleted": (append(RUNBOOK, '\nrm -f -- "$prior"\n'), "runbook-update-prior-unprotected", "never-printed"),
    "update-prior-as-output": (append(RUNBOOK, '\nbash scripts/recovery-material-s3.sh download --out "$prior"\n'), "runbook-update-prior-unprotected", "never-printed"),
    "update-prior-not-kept": (replace(RUNBOOK, GATE_KEEP_PRIOR, "also pass nothing more"), "runbook-update-prior-unprotected", "never-printed"),
    "update-premature-run-cleanup": (replace(RUNBOOK, UPDATE_CONTINUE, 'bash scripts/recovery-material.sh cleanup --dir "$run" --keep "$prior"\n' + UPDATE_CONTINUE), "runbook-cleanup-before-offline-copies", "never-printed"),
    "update-section-moved": (replace(RUNBOOK, UPDATE_HEADING, "## Updating an existing inventory\n"), "runbook-update-missing", "never-printed"),
    "runbook-offline-source-original": (replace(RUNBOOK, OFFLINE_SOURCE, "run-<YYYY-MM-DD>\\recovery-inventory.age'"), "runbook-offline-source", "never-printed"),
    "helper-tracing": (replace(HELPER, "set -euo pipefail\n", "set -euo pipefail\nset -x\n"), "helper-tracing", "never-printed"),
    "helper-debug-flag": (replace(HELPER, "  version=\"$(age --version", "  aws --debug >/dev/null\n  version=\"$(age --version"), "helper-debug-flag", "never-printed"),
    "helper-plaintext-digest": (replace(HELPER, "  rm -f -- \"${work}/plain\"\n\n", "  sha256sum -- \"${work}/plain\"\n  rm -f -- \"${work}/plain\"\n\n"), "helper-plaintext-digest", "never-printed"),
    "helper-plaintext-output": (replace(HELPER, "  rm -f -- \"${work}/plain\"\n\n", "  cat -- \"${work}/plain\"\n  rm -f -- \"${work}/plain\"\n\n"), "helper-plaintext-output", "never-printed"),
    # A digest command outside the allowlisted functions, in either helper.
    "helper-digest-outside-allowlist": (replace(HELPER, "check_output() {\n", "check_output() {\n  sha256sum -- \"$1\" >/dev/null\n"), "helper-digest-outside-allowlist", "never-printed"),
    "helper-digest-of-snapshot-elsewhere": (replace(HELPER, "source_fingerprint() {\n", "source_fingerprint() {\n  b2sum -- \"$1\" >/dev/null\n"), "helper-digest-outside-allowlist", "never-printed"),
    "s3-helper-digest-outside-allowlist": (replace(S3_HELPER, "current_checksum() {\n", "current_checksum() {\n  md5sum -- \"$file\" >/dev/null\n"), "helper-digest-outside-allowlist", "never-printed"),
    # The p2 snapshot comparison must stay a status-only comparison.
    "helper-snapshot-digest-printed": (replace(HELPER, SNAPSHOT_DIGEST_BODY, "  sha256sum -- \"$1\" >&2\n" + SNAPSHOT_DIGEST_BODY), "helper-snapshot-digest-changed", "never-printed"),
    "helper-snapshot-digest-stored": (replace(HELPER, SNAPSHOT_DIGEST_BODY, "  snapshot_sha=\"$(sha256sum -- \"$1\" | cut -d' ' -f1)\"; [[ \"$snapshot_sha\" == \"$2\" ]]\n"), "helper-snapshot-digest-changed", "never-printed"),
    "helper-snapshot-digest-renamed": (replace(HELPER, "snapshot_digest_matches() {\n", "snapshot_digest() {\n"), "helper-snapshot-digest-changed", "never-printed"),
    # Inventory template rows added for replacements.
    "template-p2-row-missing": (replace(TEMPLATE, P2_ROW, "| Interim manual p2 snapshot copy | Renamed check | "), "inventory-template-row-missing", "never-printed"),
    "template-previous-sha-row-missing": (replace(TEMPLATE, PREVIOUS_SHA_ROW, ""), "inventory-template-row-missing", "never-printed"),
    "template-p2-snapshot-hash-field": (append(TEMPLATE, "| Interim manual p2 snapshot copy | Plaintext SHA-256 | `<hash>` |\n"), "inventory-template-forbidden-field", "never-printed"),
    "template-p2-snapshot-size-field": (append(TEMPLATE, "| Interim manual p2 snapshot copy | Plain size | `<bytes>` |\n"), "inventory-template-forbidden-field", "never-printed"),
    "template-p2-filled-value": (replace(TEMPLATE, "`<recovery/stage3-p2-snapshot/YYYY-MM-DD.age, or not made>`", "`recovery/stage3-p2-snapshot/2026-10-29.age`"), "inventory-template-value", "never-printed"),
    # Recovery A and B: never overwrite or reuse a name.
    "runbook-offline-copy-item": (replace(RUNBOOK, OFFLINE_CREATE, "     Copy-Item -LiteralPath $src -Destination $dst\n"), "runbook-offline-overwrite", "never-printed"),
    "runbook-offline-copy-item-force": (replace(RUNBOOK, OFFLINE_CREATE, OFFLINE_CREATE + "     Copy-Item -Force -LiteralPath $src -Destination $dst\n"), "runbook-offline-overwrite", "never-printed"),
    "runbook-offline-create-mode": (replace(RUNBOOK, "[IO.FileMode]::CreateNew", "[IO.FileMode]::Create"), "runbook-offline-overwrite", "never-printed"),
    "runbook-offline-untimestamped-name": (replace(RUNBOOK, OFFLINE_DESTINATION, "recovery-inventory-<YYYY-MM-DD>.age'"), "runbook-offline-destination", "never-printed"),
    # Same-date updates are identified by the previous ciphertext SHA-256 too.
    "update-previous-sha-removed": (replace(RUNBOOK, UPDATE_PREVIOUS_SHA, "     --previous-key recovery/recovery-inventory/<previous YYYY-MM-DD>.age\n"), "runbook-update-validation-missing", "never-printed"),
    # The interim p2 copy stays separate from Stage 4.
    "runbook-p2-scope-removed": (replace(RUNBOOK, P2_NOT_STAGE4, "**It is the Stage 4 upload.**"), "runbook-p2-scope-missing", "never-printed"),
    "runbook-p2-section-renamed": (replace(RUNBOOK, P2_SECTION, "## Stage 4 snapshot upload\n"), "runbook-p2-scope-missing", "never-printed"),
    "runbook-p2-wildcard-cleanup": (append(RUNBOOK, "\nrm -f -- ~/hc-recovery/out/stage3-p2-snapshot*\n"), "runbook-broad-delete", "never-printed"),
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

        # --check-inventory, on a synthetic filled inventory built from the template.
        def filled_inventory(previous: str = PREVIOUS_KEY) -> str:
            lines = []
            for line in (base / TEMPLATE).read_text(encoding="utf-8").splitlines():
                cells = line.strip().strip("|").split("|") if line.lstrip().startswith("|") else []
                if len(cells) >= 2 and "<" in cells[-1]:
                    value = (
                        previous if "Previous inventory object" in line
                        else PREVIOUS_SHA if "Previous inventory ciphertext SHA-256" in line
                        else "filled"
                    )
                    line = "|".join(["", *cells[:-1], f" `{value}` ", ""])
                lines.append(line)
            return "\n".join(lines) + "\n"

        def check_inventory(text: str, *extra: str) -> subprocess.CompletedProcess[str]:
            inventory.write_text(text, encoding="utf-8")
            return run(base, "--check-inventory", str(inventory), *extra)

        good = filled_inventory()
        result = check_inventory(good)
        assert result.returncode == 0 and result.stdout.strip() == "PASS", f"filled inventory rejected:\n{result.stderr}"
        result = check_inventory(good, "--previous-key", PREVIOUS_KEY)
        assert result.returncode == 0, f"replacement with the right previous key rejected:\n{result.stderr}"
        result = check_inventory(good, "--previous-key", PREVIOUS_KEY, "--previous-sha256", PREVIOUS_SHA)
        assert result.returncode == 0, f"replacement with the right previous key and SHA-256 rejected:\n{result.stderr}"
        # A same-date replacement: the previous object key is this inventory's own key.
        result = check_inventory(good, "--previous-key", "recovery/recovery-inventory/2026-10-29.age", "--previous-sha256", PREVIOUS_SHA)
        assert result.returncode == 0, f"same-date replacement rejected:\n{result.stderr}"
        template_text = (base / TEMPLATE).read_text(encoding="utf-8")
        result = check_inventory(template_text)
        assert result.returncode == 0, "a decrypted inventory with unfilled rows must still pass without --previous-key"
        # A previous inventory made before the replacement rows existed (2026-10-29) still
        # passes the previous-inventory check, but not as a replacement.
        older = "\n".join(
            line for line in good.splitlines()
            if "Interim manual p2 snapshot copy" not in line and "Previous inventory ciphertext SHA-256" not in line
        ) + "\n"
        result = check_inventory(older)
        assert result.returncode == 0, f"a previous inventory without the replacement rows was rejected:\n{result.stderr}"
        for text, extra, rule in (
            (template_text, ("--previous-key", PREVIOUS_KEY), "inventory-placeholder-left"),
            (good, ("--previous-key", "recovery/recovery-inventory/2026-10-18.age"), "inventory-previous-key-mismatch"),
            (good, ("--previous-key", "recovery/k3s-server-token/2026-10-29.age"), "inventory-previous-key-format"),
            (good, ("--previous-key", PREVIOUS_KEY, "--previous-sha256", "d4" * 32), "inventory-previous-sha256-mismatch"),
            (good, ("--previous-key", PREVIOUS_KEY, "--previous-sha256", "D4" * 32), "inventory-previous-sha256-format"),
            (good, ("--previous-key", PREVIOUS_KEY, "--previous-sha256", "d4" * 31), "inventory-previous-sha256-format"),
            (older, ("--previous-key", PREVIOUS_KEY), "inventory-row-missing"),
            (good.replace(" Snapshot it preserves ", " Renamed field "), ("--previous-key", PREVIOUS_KEY), "inventory-row-missing"),
            (good.replace(ENC_ROW.split("|")[2], " Renamed field "), (), "inventory-row-missing"),
            (good + f"\n{FAKE_SECRET_KEY}\n", (), "age-secret-key"),
            (good + f"\n| Account | {FAKE_ACCOUNT} |\n", (), "aws-account-id"),
        ):
            result = check_inventory(text, *extra)
            assert result.returncode == 1 and f": {rule}\n" in result.stderr, f"--check-inventory missed {rule}:\n{result.stderr}"
            for value in ("filled", FAKE_SECRET_KEY, FAKE_ACCOUNT, PREVIOUS_KEY, PREVIOUS_SHA, "d4" * 31):
                assert value not in result.stdout + result.stderr, f"--check-inventory printed a value for {rule}"
        result = run(base, "--check-inventory", str(inventory), "--previous-sha256", PREVIOUS_SHA)
        assert result.returncode == 1 and "needs --check-inventory and --previous-key" in result.stderr, "--previous-sha256 accepted without --previous-key"
        link = Path(temp, "inventory-link.md")
        link.symlink_to(inventory)
        result = run(base, "--check-inventory", str(link))
        assert result.returncode == 1 and ": inventory-not-regular-file\n" in result.stderr, "--check-inventory followed a link"
        result = run(base, "--previous-key", PREVIOUS_KEY)
        assert result.returncode == 1 and "needs --check-inventory" in result.stderr, "--previous-key accepted alone"

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
    print(f"Recovery-material scanner mutation tests passed: {len(CASES)} cases, plus recipient, --scan, filled-inventory, --check-inventory and force-add checks")


if __name__ == "__main__":
    main()
