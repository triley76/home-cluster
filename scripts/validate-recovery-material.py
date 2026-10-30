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
  - the recovery-material helpers do not enable tracing or print or hash plaintext,
    and run a digest command only in the allowlisted functions: the ciphertext
    digests, and the p2 snapshot comparison with its Stage 3 checkpoint record, which
    must stay a status-only comparison;
  - the recovery-material runbook removes run files only through the helper's scoped
    cleanup, never with a wildcard or recursive rm, which could delete ciphertexts
    retained from earlier runs;
  - the runbook instructs the workstation run cleanup only after both offline
    copies (Recovery A and B) of the exact-version downloaded inventory ciphertext
    are verified, keeps the whole run directory while either is pending, and makes
    that a mandatory stop condition;
  - the runbook's inventory update decrypts the previous inventory only through the
    helper, into the inventory tmpfs, behind the keep-alive, swap and tmpfs gates;
    never displays or edits plaintext unsafely; validates the replacement and
    removes the previous plaintext before encrypting; checks the replacement against
    both the previous object key and the previous ciphertext SHA-256; and only reads,
    and finally keeps, the previous inventory ciphertext;
  - the offline copies on Recovery A and B are written under a new, timestamped
    name with create-new semantics, so an earlier copy is never overwritten;
  - the runbook keeps the interim manual p2 snapshot copy separate from Stage 4.

A finding is reported as path, line number and rule name only. Matched text is
never printed, so a failing run cannot leak the value it found.

  validate-recovery-material.py [--root DIR]
  validate-recovery-material.py --check-recipient PATH|-   (prints PASS or FAIL)
  validate-recovery-material.py --scan FILE...   (content rules only, for evidence
                                                 files and a filled inventory outside
                                                 Git; no repository files are needed)
  validate-recovery-material.py --check-inventory FILE [--previous-key KEY [--previous-sha256 HEX]]
                               (a decrypted or replacement inventory in its tmpfs: a
                               regular file, the content rules, every required row and,
                               with --previous-key, a filled replacement that has every
                               replacement row and whose previous inventory object is
                               exactly KEY, and with --previous-sha256, whose previous
                               inventory ciphertext SHA-256 is exactly HEX; prints PASS
                               or findings)

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
# A digest command may run only inside these helper functions: the ciphertext digests,
# and the p2 snapshot comparison with the SHA-256 already recorded in the Stage 3
# checkpoints file. That comparison must stay exactly this status-only body.
DIGEST_COMMAND = re.compile(r"\b(?:sha\d*sum|md5sum|b2sum|cksum)\b|\bopenssl\s+dgst\b")
DIGEST_FUNCTIONS = {
    "scripts/recovery-material.sh": {"ciphertext_sha256", "snapshot_digest_matches"},
    "scripts/recovery-material-s3.sh": {"sha256_hex"},
}
SNAPSHOT_DIGEST = (
    "snapshot_digest_matches() {",
    "  [[ \"$(sha256sum -- \"$1\" | cut -d' ' -f1)\" == \"$2\" ]]",
    "}",
)
FUNCTION_START = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{")

RUNBOOK = "docs/runbooks/encrypted-recovery-material.md"
# An rm with a wildcard or a recursive option, outside a trailing comment.
RUNBOOK_RULES = (
    ("runbook-broad-delete", re.compile(r"\brm\b[^\n#]*?(?:\*|\s-[A-Za-z]*[rR]|--recursive)")),
)
# The per-host (k3s01) and workstation cleanups both use the scoped helper.
SCOPED_CLEANUP = "recovery-material.sh cleanup --dir"
SCOPED_CLEANUP_MIN = 2
# The workstation run cleanup removes the run's inventory ciphertexts. The runbook may
# instruct it only in its gated subsection of the offline-copies section, after the
# per-device copy steps, and must keep the whole run directory while a copy is pending.
OFFLINE_SECTION = "## Offline copies on Recovery A and B"
OFFLINE_GATE = "### Workstation run cleanup (after both offline copies)"
OFFLINE_LOCK_STEP = "manage-bde -lock"
WORKSTATION_CLEANUP = 'recovery-material.sh cleanup --dir "$run"'
HOST_CLEANUP = "recovery-material.sh cleanup --dir ~/hc-recovery/out"
OFFLINE_GATE_PHRASES = (
    "Do not run the workstation run cleanup until Recovery A and Recovery B have both verified"
    " the exact-version downloaded inventory ciphertext",
    "If either device is pending or unavailable, keep the entire run directory",
    "do not remove any file from it, even one unrelated to the pending copy",
    "do not move or copy its inventory ciphertext into `~/hc-recovery`",
)
STOP_SECTION = "## Stop conditions"
OFFLINE_STOP = "an offline copy is pending or unverified when the workstation run cleanup is due. This stop is mandatory"
# The offline copies are made from the exact-version downloaded inventory ciphertext,
# to a new, timestamped name, with create-new semantics (Copy-Item overwrites).
OFFLINE_SOURCE = "\\hc-recovery\\run-<YYYY-MM-DD>\\recovery-inventory.downloaded.age'"
OFFLINE_DESTINATION = "\\home-cluster\\recovery-inventory-<YYYY-MM-DD>-<YYYYMMDDTHHMMSSZ>.age'"
OFFLINE_CREATE_NEW = "[IO.FileMode]::CreateNew"
# Applied to the code lines of the offline-copies section only.
OFFLINE_OVERWRITE = re.compile(r"(?i)\b(?:Copy-Item|cpi|Move-Item|Set-Content|Out-File|robocopy|xcopy)\b|\bcopy\s+/y\b")
# The interim manual p2 snapshot copy is documented as separate from Stage 4.
P2_SECTION = "## The interim manual p2 snapshot copy (stage3-p2-snapshot)"
P2_NOT_STAGE4 = "It is not a Stage 4 upload"
# Updating an existing inventory: the previous inventory is decrypted only by the
# helper, into the inventory tmpfs, after the keep-alive, swap and tmpfs gates. The
# replacement is validated, and the previous plaintext removed, before encryption
# (step 3). The previous inventory ciphertext ("$prior") is only read, then kept.
INVENTORY_SECTION = "## The filled inventory"
UPDATE_SECTION = "### Updating an existing inventory"
UPDATE_GATES = ("pgrep -fx 'sleep 14400'", "swapon --show", 'findmnt -no FSTYPE --mountpoint "$inv"')
DECRYPT_COMMAND = "recovery-material.sh decrypt-inventory"
DECRYPT_DIR = '--inventory-dir "$inv"'
UPDATE_VALIDATE = 'validate-recovery-material.py --check-inventory "$inv/recovery-material-inventory.md"'
UPDATE_PREVIOUS_KEY = "--previous-key recovery/recovery-inventory/"
UPDATE_PREVIOUS_SHA = "--previous-sha256 "
UPDATE_REMOVE = 'rm -f -- "$inv/previous-inventory.md"'
UPDATE_CONFIRM = 'test ! -e "$inv/previous-inventory.md"'
UPDATE_CONTINUE = "**Only then continue with step 3**"
PRIOR = '"$prior"'
PRIOR_USES = ('--ciphertext "$prior"', '--keep "$prior"')
PLAINTEXT_FILE = r"(?:previous-inventory|recovery-material-inventory)\.md"
RAW_DECRYPT = re.compile(r"\bage\b[^\n#]*\s(?:-d|--decrypt)\b")
PLAINTEXT_OUTPUT = re.compile(
    r"\b(?:cat|less|more|head|tail|bat|xxd|od|strings|tee|grep|sed|awk|nano|emacs|gedit|code|notepad(?:\.exe)?)\b"
    r"[^\n#]*" + PLAINTEXT_FILE
)
EDITOR = re.compile(r"\bvim?\b[^\n#]*" + PLAINTEXT_FILE)
SAFE_EDITOR = ("vim -n -i NONE", "set nobackup nowritebackup noundofile")
PREVIOUS_KEY_RE = re.compile(r"recovery/recovery-inventory/[0-9]{4}-[0-9]{2}-[0-9]{2}\.age")
PREVIOUS_ROW = ("", "Previous inventory object")
PREVIOUS_SHA_ROW = ("", "Previous inventory ciphertext SHA-256")
SHA256_RE = re.compile(r"[0-9a-f]{64}")

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
# Rows added after the 2026-10-29 inventory. A previous inventory may lack them, so
# they are required of the template and of a replacement (--previous-key), not of a
# decrypted previous inventory.
P2_ITEM = "Interim manual p2 snapshot copy"
REPLACEMENT_ROWS = (
    PREVIOUS_SHA_ROW,
    (P2_ITEM, "Object key"),
    (P2_ITEM, "S3 version ID"),
    (P2_ITEM, "Ciphertext SHA-256"),
    (P2_ITEM, "Ciphertext bytes"),
    (P2_ITEM, "Snapshot it preserves"),
    (P2_ITEM, "Source check"),
    (P2_ITEM, "Exact-version download comparison"),
    (P2_ITEM, "Decryption comparison"),
    (P2_ITEM, "Verification cleanup"),
    (P2_ITEM, "Restore dependencies"),
    (P2_ITEM, "Scope"),
    (P2_ITEM, "Recovery-copy status"),
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
    rules = CONTENT_RULES + (HELPER_RULES if path in HELPERS else ()) + (RUNBOOK_RULES if path == RUNBOOK else ())
    for number, line in enumerate(text.splitlines(), 1):
        for rule, pattern in rules:
            if pattern.search(line):
                findings.append((path, number, rule))


def digest_findings(path: str, text: str) -> list[tuple[str, int, str]]:
    """Digest commands outside the allowlisted helper functions, and any change to the
    p2 snapshot comparison."""
    found = []
    allowed = DIGEST_FUNCTIONS.get(path, set())
    current = None
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        start = FUNCTION_START.match(line)
        if start:
            current = start.group(1)
        if not line.lstrip().startswith("#") and DIGEST_COMMAND.search(line) and current not in allowed:
            found.append((path, number, "helper-digest-outside-allowlist"))
        if line.startswith("}") or (start and line.rstrip().endswith("}")):
            current = None
    if path == "scripts/recovery-material.sh":
        index = next((i for i, line in enumerate(lines) if line == SNAPSHOT_DIGEST[0]), None)
        if index is None or tuple(lines[index:index + len(SNAPSHOT_DIGEST)]) != SNAPSHOT_DIGEST:
            found.append((path, (index or 0) + 1, "helper-snapshot-digest-changed"))
    return found


def fenced_lines(lines: list[str], span: tuple[int, int]) -> list[tuple[int, str]]:
    """(index, line) of the lines inside code fences within a span."""
    result, fence = [], False
    for index in range(*span):
        if lines[index].lstrip().startswith("```"):
            fence = not fence
        elif fence:
            result.append((index, lines[index]))
    return result


def headings(lines: list[str]) -> list[tuple[int, int, str]]:
    """(index, level, text) of each Markdown heading outside code fences."""
    marks, fence = [], False
    for index, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fence = not fence
        elif not fence and re.match(r"#{1,6} ", line):
            marks.append((index, len(line) - len(line.lstrip("#")), line.rstrip()))
    return marks


def section_span(lines: list[str], heading: str) -> tuple[int, int] | None:
    """Line range of a section, from its heading to the next heading of the same or a higher level."""
    marks = headings(lines)
    for number, (index, level, text) in enumerate(marks):
        if text == heading:
            end = next((later for later, depth, _ in marks[number + 1:] if depth <= level), len(lines))
            return index, end
    return None


def offline_gate_findings(text: str) -> list[tuple[str, int, str]]:
    lines = text.splitlines()
    found = []
    offline = section_span(lines, OFFLINE_SECTION) or (len(lines), len(lines))
    gate = section_span(lines, OFFLINE_GATE)
    if gate is None or not (offline[0] < gate[0] and gate[1] <= offline[1]):
        found.append((RUNBOOK, 0, "runbook-offline-gate-missing"))
        gate = gate or (len(lines), len(lines))
    first = next((i for i in range(*gate) if WORKSTATION_CLEANUP in lines[i]), gate[1])
    preamble = "\n".join(lines[gate[0]:first])
    if any(phrase not in preamble for phrase in OFFLINE_GATE_PHRASES):
        found.append((RUNBOOK, 0, "runbook-offline-gate-missing"))
    if not any(OFFLINE_LOCK_STEP in lines[i] for i in range(offline[0], gate[0])):
        found.append((RUNBOOK, 0, "runbook-cleanup-before-offline-copies"))
    for index, line in enumerate(lines):
        if WORKSTATION_CLEANUP in line and not gate[0] < index < gate[1]:
            found.append((RUNBOOK, index + 1, "runbook-cleanup-before-offline-copies"))
    stop = section_span(lines, STOP_SECTION) or (0, 0)
    if OFFLINE_STOP not in "\n".join(lines[stop[0]:stop[1]]):
        found.append((RUNBOOK, 0, "runbook-offline-stop-missing"))
    sources = [line.strip() for line in lines[offline[0]:offline[1]] if line.strip().startswith("$src")]
    if not sources or any(not line.endswith(OFFLINE_SOURCE) for line in sources):
        found.append((RUNBOOK, 0, "runbook-offline-source"))
    destinations = [line.strip() for line in lines[offline[0]:offline[1]] if line.strip().startswith("$dst")]
    if not destinations or any(not line.endswith(OFFLINE_DESTINATION) for line in destinations):
        found.append((RUNBOOK, 0, "runbook-offline-destination"))
    code = fenced_lines(lines, offline)
    if not any(OFFLINE_CREATE_NEW in line for _, line in code):
        found.append((RUNBOOK, 0, "runbook-offline-overwrite"))
    for index, line in code:
        if OFFLINE_OVERWRITE.search(line):
            found.append((RUNBOOK, index + 1, "runbook-offline-overwrite"))
    if not any('--keep "$prior"' in lines[i] for i in range(*gate)):
        found.append((RUNBOOK, 0, "runbook-update-prior-unprotected"))
    return found


def line_of(lines: list[str], span: tuple[int, int], text: str) -> int | None:
    return next((i for i in range(*span) if text in lines[i]), None)


def update_findings(text: str) -> list[tuple[str, int, str]]:
    lines = text.splitlines()
    found = []
    parent = section_span(lines, INVENTORY_SECTION) or (len(lines), len(lines))
    update = section_span(lines, UPDATE_SECTION)
    if update is None or not (parent[0] < update[0] and update[1] <= parent[1]):
        found.append((RUNBOOK, 0, "runbook-update-missing"))
        update = update or (len(lines), len(lines))
    decrypt = line_of(lines, update, DECRYPT_COMMAND)
    if decrypt is None or any(line_of(lines, (update[0], decrypt), gate) is None for gate in UPDATE_GATES):
        found.append((RUNBOOK, 0, "runbook-update-gates-missing"))
    for index, line in enumerate(lines):
        number = index + 1
        if DECRYPT_COMMAND in line and not (update[0] < index < update[1] and DECRYPT_DIR in line):
            found.append((RUNBOOK, number, "runbook-decrypt-outside-tmpfs"))
        if RAW_DECRYPT.search(line):
            found.append((RUNBOOK, number, "runbook-decrypt-outside-tmpfs"))
        if PLAINTEXT_OUTPUT.search(line):
            found.append((RUNBOOK, number, "runbook-plaintext-output"))
        if EDITOR.search(line) and not all(flag in line for flag in SAFE_EDITOR):
            found.append((RUNBOOK, number, "runbook-unsafe-editor"))
        if PRIOR in line and not line.lstrip().startswith("prior=") and not any(use in line for use in PRIOR_USES):
            found.append((RUNBOOK, number, "runbook-update-prior-unprotected"))
    validate = line_of(lines, update, UPDATE_VALIDATE)
    previous_key = line_of(lines, update, UPDATE_PREVIOUS_KEY)
    previous_sha = line_of(lines, update, UPDATE_PREVIOUS_SHA)
    remove = line_of(lines, update, UPDATE_REMOVE)
    confirm = line_of(lines, update, UPDATE_CONFIRM)
    resume = line_of(lines, update, UPDATE_CONTINUE)
    if validate is None or previous_key is None or previous_sha is None or decrypt is None or not decrypt < validate:
        found.append((RUNBOOK, 0, "runbook-update-validation-missing"))
    if None in (remove, confirm, resume) or not (validate or 0) < remove < confirm < resume:
        found.append((RUNBOOK, 0, "runbook-update-previous-not-removed"))
    return found


def p2_findings(text: str) -> list[tuple[str, int, str]]:
    lines = text.splitlines()
    span = section_span(lines, P2_SECTION)
    if span is None or P2_NOT_STAGE4 not in "\n".join(lines[span[0]:span[1]]):
        return [(RUNBOOK, 0, "runbook-p2-scope-missing")]
    return []


def table_cells(line: str) -> list[str]:
    """The cells of a Markdown table data row; empty for headers, separators and other lines."""
    if not line.lstrip().startswith("|"):
        return []
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) < 2 or all(set(cell) <= set("-: ") for cell in cells) or cells[-1] == "Value":
        return []
    return cells


def check_inventory(path: Path, previous_key: str | None, previous_sha256: str | None = None) -> list[tuple[str, int, str]]:
    """Checks a decrypted or replacement inventory without printing any of its values."""
    name = str(path)
    if path.is_symlink() or not path.is_file():
        return [(name, 0, "inventory-not-regular-file")]
    raw: list[tuple[str, int, str]] = []
    scan_file(path.parent, path.name, raw, names=False)
    findings = [(name, line, rule) for _, line, rule in raw]
    rows: dict[tuple[str, str], tuple[int, str]] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        cells = table_cells(line)
        if not cells:
            continue
        rows.setdefault((cells[0] if len(cells) > 2 else "", cells[-2]), (number, cells[-1]))
        if previous_key is not None and PLACEHOLDER.fullmatch(cells[-1]):
            findings.append((name, number, "inventory-placeholder-left"))
    for row in REQUIRED_ROWS:
        if row not in rows:
            findings.append((name, 0, "inventory-row-missing"))
    if previous_key is not None:
        for row in REPLACEMENT_ROWS:
            if row not in rows:
                findings.append((name, 0, "inventory-row-missing"))
        number, value = rows.get(PREVIOUS_ROW, (0, ""))
        if not PREVIOUS_KEY_RE.fullmatch(previous_key):
            findings.append((name, 0, "inventory-previous-key-format"))
        elif value.strip("`") != previous_key:
            findings.append((name, number, "inventory-previous-key-mismatch"))
    if previous_sha256 is not None:
        number, value = rows.get(PREVIOUS_SHA_ROW, (0, ""))
        if not SHA256_RE.fullmatch(previous_sha256):
            findings.append((name, 0, "inventory-previous-sha256-format"))
        elif value.strip("`") != previous_sha256:
            findings.append((name, number, "inventory-previous-sha256-mismatch"))
    return sorted(set(findings))


def check(root: Path) -> tuple[list[tuple[str, int, str]], int]:
    findings: list[tuple[str, int, str]] = []
    files = list_files(root)

    for path in files:
        scan_file(root, path, findings)
    for path in HELPERS:
        if path in files:
            findings.extend(digest_findings(path, (root / path).read_text(encoding="utf-8")))

    recovery = [path for path in files if path.startswith("recovery/")]
    if RECIPIENT not in recovery:
        findings.append((RECIPIENT, 0, "recipient-missing"))
    elif not recipient_ok((root / RECIPIENT).read_bytes()):
        findings.append((RECIPIENT, 0, "recipient-format"))
    for path in recovery:
        if path != RECIPIENT:
            findings.append((path, 0, "recovery-unexpected-file"))

    if RUNBOOK in files:
        runbook = (root / RUNBOOK).read_text(encoding="utf-8")
        if runbook.count(SCOPED_CLEANUP) < SCOPED_CLEANUP_MIN or any(
            cleanup not in runbook for cleanup in (WORKSTATION_CLEANUP, HOST_CLEANUP)
        ):
            findings.append((RUNBOOK, 0, "runbook-scoped-cleanup-missing"))
        findings.extend(offline_gate_findings(runbook))
        findings.extend(update_findings(runbook))
        findings.extend(p2_findings(runbook))

    if TEMPLATE not in files:
        findings.append((TEMPLATE, 0, "inventory-template-missing"))
    else:
        rows = 0
        seen = set()
        for number, line in enumerate((root / TEMPLATE).read_text(encoding="utf-8").splitlines(), 1):
            cells = table_cells(line)
            if not cells:
                continue
            rows += 1
            seen.add((cells[0] if len(cells) > 2 else "", cells[-2]))
            if not PLACEHOLDER.fullmatch(cells[-1]):
                findings.append((TEMPLATE, number, "inventory-template-value"))
            if any(FORBIDDEN_FIELD.search(cell) for cell in cells[:-1]):
                findings.append((TEMPLATE, number, "inventory-template-forbidden-field"))
        if rows == 0:
            findings.append((TEMPLATE, 0, "inventory-template-empty"))
        for row in REQUIRED_ROWS + REPLACEMENT_ROWS:
            if row not in seen:
                findings.append((TEMPLATE, 0, "inventory-template-row-missing"))

    return sorted(set(findings)), len(files)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--check-recipient", metavar="PATH")
    parser.add_argument("--scan", nargs="+", metavar="FILE")
    parser.add_argument("--check-inventory", metavar="FILE")
    parser.add_argument("--previous-key", metavar="KEY")
    parser.add_argument("--previous-sha256", metavar="HEX")
    args = parser.parse_args()

    if args.previous_key is not None and not args.check_inventory:
        print("ERROR: --previous-key needs --check-inventory", file=sys.stderr)
        return 1
    if args.previous_sha256 is not None and args.previous_key is None:
        print("ERROR: --previous-sha256 needs --check-inventory and --previous-key", file=sys.stderr)
        return 1
    if args.check_inventory:
        findings = check_inventory(Path(args.check_inventory), args.previous_key, args.previous_sha256)
        for path, line, rule in findings:
            print(f"{path}:{line}: {rule}", file=sys.stderr)
        if findings:
            print(f"ERROR: {len(findings)} inventory finding(s); values are not shown", file=sys.stderr)
            return 1
        print("PASS")
        return 0

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
