#!/usr/bin/env python3
"""Fail-closed static checks for Stage 2 recovery material.

Scans every tracked file, and every untracked file that .gitignore does not
exclude, for:
  - age secret keys and age ciphertext (no ciphertext of any kind belongs in Git);
  - K3s-token-shaped values;
  - K3s secrets-encryption key material (a 32-byte base64 "secret" value, as in
    encryption-config.json);
  - 12-digit AWS account IDs, access-key IDs and secret-access-key assignments;
  - file names that suggest secret material (identities, tokens, ciphertext,
    credentials, encryption configurations, filled inventories);
and checks that:
  - recovery/ holds exactly the committed public recipient, in the expected format;
  - the blank inventory template contains placeholders only, keeps every required
    row, and has no field for a plaintext-derived value;
  - the recovery-material helpers do not enable tracing or print or hash plaintext.

A finding is reported as path, line number and rule name only. Matched text is
never printed, so a failing run cannot leak the value it found.

  validate-recovery-material.py [--root DIR]
  validate-recovery-material.py --check-recipient PATH|-   (prints PASS or FAIL)
  validate-recovery-material.py --scan FILE...   (content rules only, for evidence
                                                 files and a filled inventory outside
                                                 Git; no repository files are needed)

Tracked and staged files are always scanned, so a secret-named file that was
force-added past .gitignore is still reported.
"""

from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

RECIPIENT = "recovery/home-cluster-recovery-recipient.txt"
TEMPLATE = "docs/runbooks/recovery-material-inventory-template.md"
HELPERS = ("scripts/recovery-material.sh", "scripts/recovery-material-s3.sh")

RECIPIENT_RE = re.compile(rb"age1[02-9ac-hj-np-z]{58}\n")
# Built from fragments so this file does not match its own rules.
AGE_SECRET_MARKER = "AGE-SECRET" + "-KEY-"
AGE_CIPHERTEXT_STARTS = ("age-encryption.org" + "/v1", "-----BEGIN AGE " + "ENCRYPTED FILE-----")

CONTENT_RULES = (
    ("age-secret-key", re.compile(re.escape(AGE_SECRET_MARKER))),
    ("k3s-token", re.compile(r"K10[0-9a-fA-F]{64}::[A-Za-z]+:\S+")),
    ("k3s-token", re.compile(r"(?<![\w-])(?:server|node):[0-9a-f]{32}(?![0-9a-f])")),
    ("encryption-config-key", re.compile(r"(?i)[\"']?secret[\"']?\s*[:=]\s*[\"']?[A-Za-z0-9+/]{43}=")),
    ("aws-account-id", re.compile(r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])")),
    ("aws-access-key-id", re.compile(r"(?<![0-9A-Z])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])")),
    ("aws-secret-access-key", re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*['\"]?[A-Za-z0-9/+]{40}")),
)

HELPER_RULES = (
    ("helper-tracing", re.compile(r"^\s*set\s+(?:-[A-Za-z]*x|-o\s+xtrace)")),
    ("helper-debug-flag", re.compile(r"--debug\b")),
    ("helper-plaintext-digest", re.compile(r"\b(?:sha\d*sum|md5sum|b2sum|openssl\s+dgst)\b[^\n|]*(?:\$\{?(?:src|source|plain\w*)\b|/plain\b)")),
    ("helper-plaintext-output", re.compile(r"\b(?:cat|echo|printf|head|tail|xxd|od|less|more)\b[^\n]*(?:/plain\b|\$\{?src\}?\")")),
)

SECRET_NAMES = {"keys.txt", "token", "credentials", "kubeconfig", "recovery-material-inventory.md"}
SECRET_SUFFIXES = {".age", ".pem", ".key", ".p12", ".pfx", ".kubeconfig"}
PLACEHOLDER = re.compile(r"`?<[^<>`|]+>`?")

# Rows the inventory template must keep, as (item, field); the "Record" table
# rows have no item. The encryption-configuration rows record its ciphertext,
# object metadata, exact-version and decryption results and recovery-copy status.
ENCRYPTION_CONFIG_ITEM = "K3s secrets-encryption configuration"
REQUIRED_ROWS = (
    ("", "Previous inventory object"),
    ("K3s server token", "Object key"),
    ("K3s server token", "S3 version ID"),
    ("K3s server token", "Ciphertext SHA-256"),
    ("K3s server token", "Last verification"),
    ("Grafana admin credential", "Object key"),
    ("Grafana admin credential", "S3 version ID"),
    ("Grafana admin credential", "Ciphertext SHA-256"),
    ("Grafana admin credential", "Last verification"),
    (ENCRYPTION_CONFIG_ITEM, "Object key"),
    (ENCRYPTION_CONFIG_ITEM, "S3 version ID"),
    (ENCRYPTION_CONFIG_ITEM, "Ciphertext SHA-256"),
    (ENCRYPTION_CONFIG_ITEM, "Ciphertext bytes"),
    (ENCRYPTION_CONFIG_ITEM, "Source check"),
    (ENCRYPTION_CONFIG_ITEM, "Exact-version download comparison"),
    (ENCRYPTION_CONFIG_ITEM, "Decryption comparison"),
    (ENCRYPTION_CONFIG_ITEM, "Verification cleanup"),
    (ENCRYPTION_CONFIG_ITEM, "Key state it follows"),
    (ENCRYPTION_CONFIG_ITEM, "Recovery-copy status"),
)
# A template field must never ask for a plaintext-derived value or key material.
FORBIDDEN_FIELD = re.compile(
    r"(?i)\bplaintext\b|\bfingerprint\b|\b(?:prefix|length)\b|\bsecret value\b"
    r"|\bkey (?:name|value|material|hash)\b|\bencryption key\b|\bplain(?:text)? (?:hash|sha|size)\b"
)


def list_files(root: Path) -> list[str]:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            check=True,
            capture_output=True,
        ).stdout
        names = [name for name in out.decode("utf-8").split("\0") if name]
    except (OSError, subprocess.CalledProcessError):
        names = []
        for directory, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in files:
                names.append(Path(directory, name).relative_to(root).as_posix())
    return sorted(name for name in set(names) if (root / name).is_file())


def secret_name(path: str) -> bool:
    parts = path.split("/")
    base = parts[-1].lower()
    return (
        base in SECRET_NAMES
        or Path(base).suffix in SECRET_SUFFIXES
        or "identity" in base
        or base.startswith("grafana-admin")
        or base.startswith("encryption-config")
        or ".aws" in parts
    )


def recipient_ok(data: bytes) -> bool:
    return RECIPIENT_RE.fullmatch(data) is not None


def scan_file(root: Path, path: str, findings: list[tuple[str, int, str]], names: bool = True) -> None:
    if names and secret_name(path):
        findings.append((path, 0, "secret-file-name"))
    text = (root / path).read_bytes().decode("utf-8", errors="replace")
    if text.lstrip().startswith(AGE_CIPHERTEXT_STARTS):
        findings.append((path, 1, "age-ciphertext"))
    rules = CONTENT_RULES + (HELPER_RULES if path in HELPERS else ())
    for number, line in enumerate(text.splitlines(), 1):
        for rule, pattern in rules:
            if pattern.search(line):
                findings.append((path, number, rule))


def check(root: Path) -> tuple[list[tuple[str, int, str]], int]:
    findings: list[tuple[str, int, str]] = []
    files = list_files(root)

    for path in files:
        scan_file(root, path, findings)

    recovery = [path for path in files if path.startswith("recovery/")]
    if RECIPIENT not in recovery:
        findings.append((RECIPIENT, 0, "recipient-missing"))
    elif not recipient_ok((root / RECIPIENT).read_bytes()):
        findings.append((RECIPIENT, 0, "recipient-format"))
    for path in recovery:
        if path != RECIPIENT:
            findings.append((path, 0, "recovery-unexpected-file"))

    if TEMPLATE not in files:
        findings.append((TEMPLATE, 0, "inventory-template-missing"))
    else:
        rows = 0
        seen = set()
        for number, line in enumerate((root / TEMPLATE).read_text(encoding="utf-8").splitlines(), 1):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")] if line.lstrip().startswith("|") else []
            if len(cells) < 2 or all(set(cell) <= set("-: ") for cell in cells) or cells[-1] == "Value":
                continue
            rows += 1
            seen.add((cells[0] if len(cells) > 2 else "", cells[-2]))
            if not PLACEHOLDER.fullmatch(cells[-1]):
                findings.append((TEMPLATE, number, "inventory-template-value"))
            if any(FORBIDDEN_FIELD.search(cell) for cell in cells[:-1]):
                findings.append((TEMPLATE, number, "inventory-template-forbidden-field"))
        if rows == 0:
            findings.append((TEMPLATE, 0, "inventory-template-empty"))
        for row in REQUIRED_ROWS:
            if row not in seen:
                findings.append((TEMPLATE, 0, "inventory-template-row-missing"))

    return sorted(set(findings)), len(files)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--check-recipient", metavar="PATH")
    parser.add_argument("--scan", nargs="+", metavar="FILE")
    args = parser.parse_args()

    if args.scan:
        findings = []
        for name in args.scan:
            path = Path(name).resolve()
            if not path.is_file():
                print(f"ERROR: not a file: {name}", file=sys.stderr)
                return 1
            scan_file(path.parent, path.name, findings, names=False)
        for path, line, rule in sorted(set(findings)):
            print(f"{path}:{line}: {rule}", file=sys.stderr)
        if findings:
            print(f"ERROR: {len(set(findings))} finding(s); matched text is not shown", file=sys.stderr)
            return 1
        print(f"No findings in {len(args.scan)} file(s)")
        return 0

    if args.check_recipient:
        try:
            data = sys.stdin.buffer.read() if args.check_recipient == "-" else Path(args.check_recipient).read_bytes()
        except OSError:
            data = b""
        ok = recipient_ok(data)
        print("PASS" if ok else "FAIL")
        return 0 if ok else 1

    findings, scanned = check(Path(args.root))
    for path, line, rule in findings:
        print(f"{path}:{line}: {rule}", file=sys.stderr)
    if findings:
        print(f"ERROR: {len(findings)} recovery-material finding(s); matched text is not shown", file=sys.stderr)
        return 1
    print(f"Recovery-material checks passed ({scanned} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
