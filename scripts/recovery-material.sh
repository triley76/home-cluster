#!/usr/bin/env bash
# Stage 2 recovery-material helper, run on the host that holds the plaintext.
#
# Subcommands:
#   check-recipient
#       Validate the committed public recipient. Prints PASS or FAIL only.
#   encrypt --item ITEM --source FILE --out FILE.age
#       Encrypt FILE directly with the committed recipient. Prints the ciphertext
#       path, size and SHA-256.
#   verify --item ITEM --ciphertext FILE.age --source FILE --identity-archive FILE.age
#          [--ciphertext-sha256 HEX]
#       Decrypt a downloaded ciphertext into a private tmpfs and compare it with the
#       source using cmp -s. Prints MATCH, DIFFER or ERROR and the cmp exit status.
#       With --ciphertext-sha256 (required for stage3-p2-snapshot), the ciphertext
#       must have that SHA-256 before anything is decrypted.
#   start-run --dir DIR
#       Create DIR (mode 0700, which must not exist) as this run's directory, with a
#       run marker. Every file a run creates or transports on this host goes in it.
#   cleanup --dir DIR [--remove NAME]... [--keep FILE]...
#       Remove exactly the named run files, then the marker and DIR, and confirm that
#       each kept file (a ciphertext retained from an earlier run, outside DIR) is
#       unchanged. Before removing anything it refuses: a DIR without the marker; a
#       name other than ITEM.age, ITEM.downloaded.age or identity-archive.age; a
#       missing, linked, foreign or pre-run file; and any entry not named. Never
#       needs root, and refuses it.
#   decrypt-inventory --inventory-dir DIR --ciphertext FILE.age --ciphertext-sha256 HEX
#                     --identity-archive FILE.age --archive-sha256 HEX
#       Decrypt the previous inventory, for an update, to DIR/previous-inventory.md
#       only. DIR must be the operator's private inventory tmpfs (a mode 0700 tmpfs
#       mount point), swap must be off and a terminal available for age's own
#       passphrase prompt. Both inputs must be absolute, normalized, regular files
#       with no symbolic link in their path, outside DIR. They are only read: private
#       copies in DIR are checked against the expected SHA-256 and header (one X25519
#       stanza; one scrypt stanza), decrypted from, and removed on exit. The result
#       must be a nonempty, singly linked, mode 600 file that passes
#       validate-recovery-material.py --check-inventory, or it is removed. Nothing
#       from the plaintext is printed. Never needs root, and refuses it.
#
# Items: k3s-server-token, grafana-admin, recovery-inventory, encryption-config,
# stage3-p2-snapshot.
# encryption-config is the K3s secrets-encryption configuration (Stage 3). Its
# --source must be exactly /var/lib/rancher/k3s/server/cred/encryption-config.json:
# no other path, alias or symbolic-link component, with a canonical path equal to
# it. The file must be owned by root:root, and its directory must be a real
# directory owned by root:root and not writable by group or others.
#
# stage3-p2-snapshot is the interim, manually preserved copy of the Stage 3 p2
# (post-encryption) etcd snapshot. It is not a Stage 4 upload: those are K3s's own
# uploads under etcd/. Its --source must be:
#   - directly in /var/lib/rancher/k3s/server/db/snapshots, a root:root directory
#     that group and others cannot write to, with no symbolic link in its path;
#   - named stage3-p2-post-encryption-<YYYYMMDD>t<HHMMSS>z-k3s01-<epoch>;
#   - a regular root:root file, mode 600, singly linked, at most 64 MiB, whose
#     canonical path is itself;
#   - the only p2-post-encryption record in the Stage 3 checkpoints file
#     (/var/lib/homelab-secrets-encryption/checkpoints, root:root, no group or other
#     access, in a root:root directory), with the same name, size, modification time
#     and SHA-256. The snapshot digest is compared with that record and never printed.
# encrypt checks the source again after encryption and removes the ciphertext if it
# changed. It must run through sudo from the operator's own (non-root) account, so
# that the ciphertext is created by the operator. verify needs --ciphertext-sha256
# and uses an 80 MiB private tmpfs, after checking that twice that much memory is
# available.
#
# Production runs as root (through sudo). The helper never prints plaintext,
# plaintext sizes or plaintext hashes; age reads the source file itself.
# encrypt creates the output exclusively (it never overwrites or follows an existing
# path), and under sudo writes it as the invoking user, so root never writes into the
# operator's directory. It then requires the output to be a regular, singly linked,
# mode 600 file owned by the operator (the sudo user, or the caller without sudo), and
# otherwise removes it. verify:
#   - refuses to run while any swap device is active, because tmpfs pages can be
#     written to swap;
#   - mounts its own root-owned 0700 tmpfs, verifies the mount, and on exit removes
#     its files and unmounts it, including on error and on INT, TERM and HUP;
#   - accepts only a passphrase-encrypted identity archive (one scrypt stanza),
#     copies it into the tmpfs, and lets age prompt for the passphrase on /dev/tty.
#     The passphrase is never accepted through arguments, environment variables,
#     files or stdin; age runs with stdin from /dev/null, and the helper refuses to
#     run when AGE_* or *PASSPHRASE* variables are set. The caller's own copy of the
#     archive is not touched; removing it is a separate runbook step.
# The helper never installs or downloads software; it requires age v1.3.2 exactly.
#
# Test mode (RECOVERY_MATERIAL_TEST=1, refused for root) replaces the recipient,
# the identity and the tmpfs with paths supplied by scripts/test-recovery-material.sh.
# For encryption-config it also replaces, from test-only variables:
#   - the expected source path, with RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE (an
#     absolute, normalized path);
#   - the required root:root owner of the file and of its directory, with
#     RECOVERY_MATERIAL_TEST_SOURCE_OWNER and RECOVERY_MATERIAL_TEST_PARENT_OWNER
#     (uid:gid, default the test user's own).
# For stage3-p2-snapshot, the same owner variables apply, and also:
#   - RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR and RECOVERY_MATERIAL_TEST_CHECKPOINTS
#     replace the snapshot directory and the checkpoints file (absolute, normalized);
#   - RECOVERY_MATERIAL_TEST_SUDO_USER and RECOVERY_MATERIAL_TEST_SUDO_UID stand in
#     for SUDO_USER and SUDO_UID, so that encrypt writes through the runuser found on
#     PATH (a stub in the tests);
#   - RECOVERY_MATERIAL_TEST_MEMINFO replaces /proc/meminfo for the memory check.
# These variables are refused outright outside test mode, so they can never
# override a production source path or owner.
# Test mode does NOT exercise sudo, the real runuser, the tmpfs mount, the swap
# check, the passphrase prompt, SSH, AWS or S3.
#
# Requires: bash, age v1.3.2, coreutils, util-linux (mount, umount, findmnt, runuser).
set -euo pipefail

case "$-" in
  *x* | *v*)
    echo "ERROR: shell tracing is enabled; refusing to run" >&2
    exit 1
    ;;
esac
if [[ -n "${BASH_XTRACEFD:-}" ]]; then
  echo "ERROR: BASH_XTRACEFD is set; refusing to run" >&2
  exit 1
fi
umask 077
unset HISTFILE
set +o history 2>/dev/null || true

AGE_VERSION_REQUIRED="v1.3.2"
ITEMS=(k3s-server-token grafana-admin recovery-inventory encryption-config stage3-p2-snapshot)
# Items whose source must be owned by root:root (uid 0, gid 0).
ROOT_OWNED_ITEMS=(encryption-config stage3-p2-snapshot)
# The only production source of encryption-config.
ENCRYPTION_CONFIG_SOURCE="/var/lib/rancher/k3s/server/cred/encryption-config.json"
# stage3-p2-snapshot: the K3s snapshot directory, the Stage 3 checkpoints file, the
# p2 snapshot name and checkpoint label, the size cap, and verify's tmpfs size (the
# cap plus room for the identity archive; the other items use 4 MiB).
SNAPSHOT_DIR="/var/lib/rancher/k3s/server/db/snapshots"
CHECKPOINTS_FILE="/var/lib/homelab-secrets-encryption/checkpoints"
SNAPSHOT_NAME_RE='^stage3-p2-post-encryption-[0-9]{8}t[0-9]{6}z-k3s01-[0-9]{10}$'
SNAPSHOT_LABEL="p2-post-encryption"
SNAPSHOT_MAX_BYTES=$(( 64 * 1024 * 1024 ))
SNAPSHOT_TMPFS_MIB=80
SMALL_TMPFS_MIB=4
# Created by start-run in each run directory; cleanup refuses a directory without it.
RUN_MARKER=".recovery-run"
# Fixed names in the inventory tmpfs during an update. encrypt refuses the inventory
# while the previous plaintext or either decryption copy is still beside its source.
PREVIOUS_PLAINTEXT="previous-inventory.md"
PREVIOUS_COPY="previous-inventory.age"
ARCHIVE_COPY="identity-archive.age"
REPLACEMENT_NAME="recovery-material-inventory.md"
TEST_ONLY_VARIABLES=(RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE RECOVERY_MATERIAL_TEST_SOURCE_OWNER RECOVERY_MATERIAL_TEST_PARENT_OWNER
  RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR RECOVERY_MATERIAL_TEST_CHECKPOINTS RECOVERY_MATERIAL_TEST_SUDO_USER
  RECOVERY_MATERIAL_TEST_SUDO_UID RECOVERY_MATERIAL_TEST_MEMINFO)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPIENT_FILE="$(cd "${script_dir}/.." && pwd)/recovery/home-cluster-recovery-recipient.txt"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

test_mode=0
if [[ "${RECOVERY_MATERIAL_TEST:-}" == "1" ]]; then
  [[ "$(id -u)" -ne 0 ]] || die "test mode must not run as root"
  test_mode=1
  RECIPIENT_FILE="${RECOVERY_MATERIAL_TEST_RECIPIENT:-$RECIPIENT_FILE}"
fi
if (( ! test_mode )); then
  for name in "${TEST_ONLY_VARIABLES[@]}"; do
    [[ -z "${!name+set}" ]] || die "${name} is test-only and is refused outside test mode"
  done
fi

require_root() {
  if (( ! test_mode )); then
    [[ "$(id -u)" -eq 0 ]] || die "run this subcommand as root, through sudo"
  fi
}

require_age() {
  command -v age >/dev/null 2>&1 \
    || die "age is not installed; ${AGE_VERSION_REQUIRED} is a separately approved prerequisite on this host"
  local version
  version="$(age --version 2>/dev/null)" || die "could not read the age version"
  [[ "$version" == "$AGE_VERSION_REQUIRED" ]] \
    || die "age ${AGE_VERSION_REQUIRED} is required (found ${version:-unknown})"
}

refuse_passphrase_env() {
  local name
  for name in $(compgen -e); do
    case "$name" in
      AGE_* | *PASSPHRASE*) die "environment variable ${name} is set; unset it and retry" ;;
    esac
  done
}

require_item() {
  local item="$1" known
  for known in "${ITEMS[@]}"; do
    [[ "$item" == "$known" ]] && return 0
  done
  die "unknown item: ${item} (expected one of: ${ITEMS[*]})"
}

# One line: age1 followed by 58 bech32 characters, LF-terminated, no CR.
recipient_ok() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(wc -c < "$file")" -eq 63 && "$(wc -l < "$file")" -eq 1 ]] || return 1
  LC_ALL=C grep -Eq '^age1[02-9ac-hj-np-z]{58}$' "$file"
}

# Checks the age header only: the version line, then exactly one stanza of the
# expected type before the MAC line. The payload is never read or printed.
header_ok() {
  local file="$1" want="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  LC_ALL=C awk -v want="$want" '
    NR == 1 { if ($0 != "age-encryption.org/v1") { bad = 1; exit } next }
    /^-> / { stanzas++; if ($2 != want) bad = 1; next }
    /^--- / { mac = 1; exit }
    NR > 64 { bad = 1; exit }
    END { exit (bad || !mac || stanzas != 1) ? 1 : 0 }
  ' "$file"
}

root_owned_item() {
  local known
  for known in "${ROOT_OWNED_ITEMS[@]}"; do
    [[ "$1" == "$known" ]] && return 0
  done
  return 1
}

required_owner() {
  if (( test_mode )); then
    printf '%s' "${RECOVERY_MATERIAL_TEST_SOURCE_OWNER:-$(id -u):$(id -g)}"
  else
    printf '0:0'
  fi
}

required_parent_owner() {
  if (( test_mode )); then
    printf '%s' "${RECOVERY_MATERIAL_TEST_PARENT_OWNER:-$(id -u):$(id -g)}"
  else
    printf '0:0'
  fi
}

expected_source() {
  local expected="$ENCRYPTION_CONFIG_SOURCE"
  if (( test_mode )) && [[ -n "${RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE:-}" ]]; then
    expected="$RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE"
    [[ "$expected" =~ ^(/[^/]+)+$ && "${expected}/" != */./* && "${expected}/" != */../* ]] \
      || die "RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE must be an absolute, normalized path"
  fi
  printf '%s' "$expected"
}

# A test-only path override (absolute, normalized), or the production default.
test_path() {
  local name="$1" default="$2" value
  value="${!name:-}"
  if (( test_mode )) && [[ -n "$value" ]]; then
    [[ "$value" =~ ^(/[^/]+)+$ && "${value}/" != */./* && "${value}/" != */../* ]] \
      || die "${name} must be an absolute, normalized path"
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

snapshot_dir() { test_path RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR "$SNAPSHOT_DIR"; }
checkpoints_file() { test_path RECOVERY_MATERIAL_TEST_CHECKPOINTS "$CHECKPOINTS_FILE"; }

# A directory that a bound source or record lies in: no component of its path is a
# symbolic link, and it is a root:root directory that group and others cannot write
# to. Metadata only.
check_trusted_dir() {
  local label="$1" dir="$2" prefix="" part mode owner
  local -a parts
  IFS='/' read -r -a parts <<<"${dir#/}"
  for part in "${parts[@]}"; do
    prefix+="/${part}"
    [[ ! -L "$prefix" ]] || die "a directory in the source path is a symbolic link: ${prefix}"
  done
  [[ -e "$dir" ]] || die "the ${label} does not exist: ${dir}"
  [[ -d "$dir" ]] || die "the ${label} is not a directory: ${dir}"
  read -r mode owner < <(stat -c '%a %u:%g' -- "$dir")
  [[ "$owner" == "$(required_parent_owner)" ]] \
    || die "the ${label} is not owned by root:root (owner ${owner}): ${dir}"
  (( (8#${mode} & 8#022) == 0 )) \
    || die "the ${label} is writable by group or others (mode ${mode}): ${dir}"
}

# encryption-config only, before any other source check: the path must be exactly
# the expected one, in a trusted credential directory. Metadata only.
check_bound_source() {
  local src="$1" expected
  expected="$(expected_source)"
  [[ "$src" == "$expected" ]] || die "the encryption-config source must be exactly ${expected}"
  check_trusted_dir "credential directory" "${expected%/*}"
}

# stage3-p2-snapshot only, before any other source check: an absolute, normalized
# path directly in the trusted snapshot directory, with a p2 snapshot name.
check_snapshot_source() {
  local src="$1" dir
  dir="$(snapshot_dir)"
  normalized_path "$src" || die "the stage3-p2-snapshot source must be an absolute, normalized path: ${src}"
  [[ "${src%/*}" == "$dir" ]] || die "the stage3-p2-snapshot source must be directly in ${dir}: ${src}"
  [[ "${src##*/}" =~ $SNAPSHOT_NAME_RE ]] \
    || die "the stage3-p2-snapshot source is not named as a p2 post-encryption snapshot: ${src}"
  check_trusted_dir "snapshot directory" "$dir"
}

# The only digest of a source the helpers compute: the p2 snapshot's SHA-256, compared
# with the value already recorded in the Stage 3 checkpoints file. Only the exit
# status leaves this function; the digest is never printed or stored.
snapshot_digest_matches() {
  [[ "$(sha256sum -- "$1" | cut -d' ' -f1)" == "$2" ]]
}

# stage3-p2-snapshot only: the source must be the single p2 record in the Stage 3
# checkpoints file ("<mtime> <label> <name> <size> <sha256> token=present"), with the
# same name, size, modification time and SHA-256. The file holds snapshot metadata
# only; nothing from it is printed. Sets recorded_sha256 for the post-encryption check.
check_checkpoint() {
  local src="$1" file mode owner links count labelled
  local -a fields
  file="$(checkpoints_file)"
  check_trusted_dir "checkpoint directory" "${file%/*}"
  [[ ! -L "$file" ]] || die "the checkpoints file is a symbolic link: ${file}"
  [[ -f "$file" ]] || die "the checkpoints file does not exist or is not a regular file: ${file}"
  read -r mode owner links < <(stat -c '%a %u:%g %h' -- "$file")
  [[ "$owner" == "$(required_owner)" ]] || die "the checkpoints file is not owned by root:root (owner ${owner}): ${file}"
  (( (8#${mode} & 8#077) == 0 )) || die "the checkpoints file is accessible to group or others (mode ${mode}): ${file}"
  [[ "$links" == "1" ]] || die "the checkpoints file has other hard links: ${file}"
  count="$(awk -v name="${src##*/}" '$3 == name' "$file" | wc -l)"
  [[ "$count" -eq 1 ]] || die "the checkpoints file must hold exactly one record for the source (found ${count})"
  labelled="$(awk -v label="$SNAPSHOT_LABEL" '$2 == label' "$file" | wc -l)"
  [[ "$labelled" -eq 1 ]] || die "the checkpoints file must hold exactly one ${SNAPSHOT_LABEL} record (found ${labelled})"
  read -r -a fields < <(awk -v name="${src##*/}" '$3 == name' "$file")
  [[ "${#fields[@]}" -eq 6 && "${fields[0]}" =~ ^[0-9]+$ && "${fields[1]}" == "$SNAPSHOT_LABEL" \
    && "${fields[3]}" =~ ^[0-9]+$ && "${fields[4]}" =~ ^[0-9a-f]{64}$ && "${fields[5]}" == "token=present" ]] \
    || die "the checkpoint record for the source is malformed or is not the ${SNAPSHOT_LABEL} record"
  [[ "$(stat -c '%s' -- "$src")" == "${fields[3]}" ]] || die "the source size differs from its checkpoint record"
  [[ "$(stat -c '%Y' -- "$src")" == "${fields[0]}" ]] || die "the source modification time differs from its checkpoint record"
  snapshot_digest_matches "$src" "${fields[4]}" || die "the source SHA-256 differs from its checkpoint record"
  recorded_sha256="${fields[4]}"
}

# Identity of the source file, compared before and after encryption. Never printed.
source_fingerprint() {
  stat -c '%d:%i %h %s %Y %Z' -- "$1"
}

# After the file checks: the canonical path of the existing file is the expected path.
check_canonical_source() {
  local src="$1" resolved
  resolved="$(realpath -e -- "$src")" || die "the source path could not be resolved: ${src}"
  [[ "$resolved" == "$(expected_source)" ]] \
    || die "the source path does not resolve to the expected path: ${src}"
}

# Metadata only (lstat and stat), except that a stage3-p2-snapshot source is also
# read once for the status-only comparison with its checkpoint SHA-256. Sets
# source_report, a line that is safe to print.
check_source() {
  local item="$1" src="$2" mode owner links size
  if [[ "$item" == "encryption-config" ]]; then
    check_bound_source "$src"
  elif [[ "$item" == "stage3-p2-snapshot" ]]; then
    check_snapshot_source "$src"
  fi
  [[ -e "$src" || -L "$src" ]] || die "source does not exist: ${src}"
  [[ ! -L "$src" ]] || die "source is a symbolic link: ${src}"
  [[ -f "$src" ]] || die "source is not a regular file: ${src}"
  [[ -s "$src" ]] || die "source is empty: ${src}"
  read -r mode owner < <(stat -c '%a %u:%g' -- "$src")
  (( (8#${mode} & 8#077) == 0 )) \
    || die "source is accessible to group or others (mode ${mode}): ${src}"
  source_report="PASS (regular file, nonempty, mode ${mode}, no group or other access"
  if root_owned_item "$item"; then
    [[ "$owner" == "$(required_owner)" ]] \
      || die "source is not owned by root:root (owner ${owner}): ${src}"
    source_report+=", owner root:root"
  fi
  if [[ "$item" == "encryption-config" ]]; then
    check_canonical_source "$src"
    source_report+=", expected path, directory root:root and not group or other writable"
  elif [[ "$item" == "stage3-p2-snapshot" ]]; then
    read -r links size < <(stat -c '%h %s' -- "$src")
    [[ "$mode" == "600" ]] || die "the stage3-p2-snapshot source must be mode 600 (mode ${mode}): ${src}"
    [[ "$links" == "1" ]] || die "the stage3-p2-snapshot source has other hard links: ${src}"
    (( size <= SNAPSHOT_MAX_BYTES )) || die "the stage3-p2-snapshot source exceeds the 64 MiB cap: ${src}"
    [[ "$(realpath -e -- "$src" 2>/dev/null)" == "$src" ]] \
      || die "the source path does not resolve to itself: ${src}"
    check_checkpoint "$src"
    source_report+=", single link, within the 64 MiB cap, snapshot directory root:root and not group or other writable"
    source_report+=", the only ${SNAPSHOT_LABEL} checkpoint record with matching name, size, time and SHA-256"
  fi
  source_report+=")"
}

# The account that called sudo, if it is not root; empty otherwise. In test mode,
# RECOVERY_MATERIAL_TEST_SUDO_USER and RECOVERY_MATERIAL_TEST_SUDO_UID stand in for
# SUDO_USER and SUDO_UID.
sudo_user() {
  local user
  if (( test_mode )); then user="${RECOVERY_MATERIAL_TEST_SUDO_USER:-}"; else user="${SUDO_USER:-}"; fi
  [[ "$user" == "root" ]] && user=""
  printf '%s' "$user"
}

# The operator's uid: the sudo user's, or the caller's own without sudo.
operator_uid() {
  if [[ -z "$(sudo_user)" ]]; then
    id -u
  elif (( test_mode )); then
    printf '%s' "${RECOVERY_MATERIAL_TEST_SUDO_UID:-}"
  else
    printf '%s' "${SUDO_UID:-}"
  fi
}

# stage3-p2-snapshot is encrypted through sudo from the operator's own account, so
# that the operator, not root, creates the ciphertext that is copied and cleaned up.
require_sudo_operator() {
  [[ -n "$(sudo_user)" && "$(operator_uid)" =~ ^[1-9][0-9]*$ ]] \
    || die "${1} must be encrypted through sudo from the operator's own (non-root) account"
}

# The output directory must be a real directory owned by the operator (or root) and
# not writable by group or others.
check_out_dir() {
  local dir="$1" owner mode
  [[ -d "$dir" && ! -L "$dir" ]] || die "output directory does not exist or is a symbolic link: ${dir}"
  read -r owner mode < <(stat -c '%u %a' -- "$dir")
  [[ "$owner" == "$(operator_uid)" || "$owner" == "0" ]] || die "output directory is not owned by the operator: ${dir}"
  (( (8#${mode} & 8#022) == 0 )) || die "output directory is writable by group or others (mode ${mode}): ${dir}"
}

# The written ciphertext must be a regular, singly linked, mode 600 file owned by the
# operator; otherwise the name this run created is removed.
check_output() {
  local out="$1"
  if [[ -f "$out" && ! -L "$out" && "$(stat -c '%u %a %h' -- "$out")" == "$(operator_uid) 600 1" ]]; then
    return 0
  fi
  [[ -f "$out" && ! -L "$out" ]] && rm -f -- "$out"
  die "the ciphertext is not a regular, singly linked, mode 600 file owned by the operator; it was removed"
}

ciphertext_sha256() {
  sha256sum -- "$1" | cut -d' ' -f1
}

recorded_sha256=""
parse_args() {
  item="" src="" out="" ciphertext="" archive="" expected_sha256=""
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --item) item="$2" ;;
      --source) src="$2" ;;
      --out) out="$2" ;;
      --ciphertext) ciphertext="$2" ;;
      --identity-archive) archive="$2" ;;
      --ciphertext-sha256) expected_sha256="$2" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done
}

cmd_check_recipient() {
  if recipient_ok "$RECIPIENT_FILE"; then
    echo "PASS"
  else
    echo "FAIL"
    return 1
  fi
}

# Writes standard input to $1, creating it exclusively (O_EXCL through noclobber).
# Under sudo, the file is created by the invoking user, not by root.
write_exclusive() {
  local target="$1" user
  user="$(sudo_user)"
  if [[ -n "$user" ]]; then
    # $1 is expanded by the child shell, which receives "$target" as its first argument.
    # shellcheck disable=SC2016
    runuser -u "$user" -- bash -c 'umask 077; set -C; exec cat >"$1"' write_exclusive "$target"
  else
    (set -C; exec cat >"$target")
  fi
}

cmd_encrypt() {
  parse_args "$@"
  [[ -n "$item" && -n "$src" && -n "$out" ]] || die "encrypt needs --item, --source and --out"
  require_item "$item"
  if [[ "$item" == "recovery-inventory" ]]; then
    local leftover
    for leftover in "$PREVIOUS_PLAINTEXT" "$PREVIOUS_COPY" "$ARCHIVE_COPY"; do
      [[ ! -e "$(dirname -- "$src")/${leftover}" && ! -L "$(dirname -- "$src")/${leftover}" ]] \
        || die "remove ${leftover} from the inventory directory before encrypting the inventory"
    done
  fi
  [[ "$out" == *.age ]] || die "output must end in .age"
  [[ ! -e "$out" && ! -L "$out" ]] || die "output already exists: ${out}"
  require_root
  [[ "$item" != "stage3-p2-snapshot" ]] || require_sudo_operator "$item"
  check_out_dir "$(dirname -- "$out")"
  require_age
  recipient_ok "$RECIPIENT_FILE" || die "the committed recipient failed validation"
  check_source "$item" "$src"

  local status=0 before
  before="$(source_fingerprint "$src")"
  age -R "$RECIPIENT_FILE" -- "$src" </dev/null | write_exclusive "$out" || status=$?
  if (( status != 0 )); then
    # Remove only a regular file this run may have created; never follow a link.
    [[ -f "$out" && ! -L "$out" ]] && rm -f -- "$out"
    die "age encryption or the exclusive write failed"
  fi
  check_output "$out"
  if ! header_ok "$out" X25519; then
    rm -f -- "$out"
    die "the ciphertext header check failed"
  fi
  # The snapshot must still be the checkpointed file that age read.
  if [[ "$item" == "stage3-p2-snapshot" ]]; then
    if [[ "$(source_fingerprint "$src")" != "$before" ]] || ! snapshot_digest_matches "$src" "$recorded_sha256"; then
      rm -f -- "$out"
      die "the source changed during encryption; the ciphertext was removed"
    fi
  fi

  printf 'item: %s\n' "$item"
  printf 'source check: %s\n' "$source_report"
  printf 'ciphertext: %s\n' "$out"
  printf 'ciphertext bytes: %s\n' "$(wc -c < "$out")"
  printf 'ciphertext sha256: %s\n' "$(ciphertext_sha256 "$out")"
}

work="" mounted=0 production_dir=0
cleanup() {
  local status=$? failed=0
  if [[ -n "$work" ]]; then
    rm -f -- "${work}/plain" "${work}/identity-archive.age" 2>/dev/null || failed=1
    if [[ -e "${work}/plain" || -e "${work}/identity-archive.age" ]]; then
      failed=1
    fi
    if (( mounted )); then
      if umount -- "$work" 2>/dev/null || umount -l -- "$work" 2>/dev/null; then
        mounted=0
      else
        failed=1
      fi
    fi
    if (( production_dir && ! mounted )); then
      rmdir -- "$work" 2>/dev/null || failed=1
    fi
  fi
  if (( failed )); then
    printf 'ERROR: cleanup of %s failed; remove its files and unmount it before continuing\n' "$work" >&2
    # Keep the original failure status; turn a success into a failure.
    (( status != 0 )) || status=1
  fi
  exit "$status"
}

swap_active() {
  [[ -r /proc/swaps ]] || return 0
  (( $(wc -l < /proc/swaps) > 1 ))
}

# verify's private tmpfs size in MiB: room for the snapshot cap and the identity
# archive for stage3-p2-snapshot, 4 MiB for the small items.
tmpfs_mib() {
  if [[ "$1" == "stage3-p2-snapshot" ]]; then
    printf '%s' "$SNAPSHOT_TMPFS_MIB"
  else
    printf '%s' "$SMALL_TMPFS_MIB"
  fi
}

# Requires MemAvailable to be at least twice the tmpfs size, so that filling the
# tmpfs cannot push the host into memory pressure.
check_memory() {
  local mib="$1" meminfo available
  meminfo="$(test_path RECOVERY_MATERIAL_TEST_MEMINFO /proc/meminfo)"
  available="$(awk '$1 == "MemAvailable:" { print $2 }' "$meminfo" 2>/dev/null)" || available=""
  [[ "$available" =~ ^[0-9]+$ ]] || die "could not read MemAvailable"
  (( available >= mib * 1024 * 2 )) \
    || die "not enough available memory for the ${mib} MiB private tmpfs (twice its size is required)"
}

mount_private_tmpfs() {
  local mib="$1" sources
  # Captured first: with pipefail, `findmnt | grep -q` can fail on SIGPIPE.
  sources="$(findmnt -rn -t tmpfs -o SOURCE)" || die "could not list tmpfs mounts"
  if grep -qx 'recovery-material' <<<"$sources"; then
    die "an earlier recovery-material tmpfs is still mounted; unmount it first (findmnt -t tmpfs -S recovery-material)"
  fi
  work="$(mktemp -d /run/recovery-material.XXXXXX)" || die "could not create the mount point"
  production_dir=1
  mount -t tmpfs -o "size=${mib}m,mode=0700,uid=0,gid=0,noexec,nosuid,nodev" recovery-material "$work" \
    || die "could not mount the private tmpfs"
  mounted=1
  [[ "$(findmnt -no FSTYPE --mountpoint "$work")" == "tmpfs" ]] \
    || die "the private tmpfs mount could not be verified"
  [[ "$(stat -c '%a %u' -- "$work")" == "700 0" ]] \
    || die "the private tmpfs has unexpected ownership or mode"
}

use_test_tmpdir() {
  local dir="${RECOVERY_MATERIAL_TEST_TMPDIR:-}"
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || die "test mode needs RECOVERY_MATERIAL_TEST_TMPDIR"
  [[ "$(stat -c '%a %u' -- "$dir")" == "700 $(id -u)" ]] || die "the test directory must be mode 700"
  [[ -z "$(ls -A -- "$dir")" ]] || die "the test directory must be empty"
  work="$dir"
}

cmd_verify() {
  parse_args "$@"
  [[ -n "$item" && -n "$ciphertext" && -n "$src" ]] || die "verify needs --item, --ciphertext and --source"
  require_item "$item"
  if [[ "$item" == "stage3-p2-snapshot" && -z "$expected_sha256" ]]; then
    die "${item} verify needs --ciphertext-sha256, the SHA-256 that encrypt printed"
  fi
  require_root
  require_age
  refuse_passphrase_env
  header_ok "$ciphertext" X25519 || die "the ciphertext header check failed"
  if [[ -n "$expected_sha256" ]]; then
    sha256_ok "$expected_sha256" || die "--ciphertext-sha256 must be 64 hexadecimal characters"
    [[ "$(ciphertext_sha256 "$ciphertext")" == "${expected_sha256,,}" ]] \
      || die "the ciphertext does not have the expected SHA-256 (incomplete or different transfer); nothing was decrypted"
  fi
  check_source "$item" "$src"
  local mib
  mib="$(tmpfs_mib "$item")"
  check_memory "$mib"

  local identity
  if [[ -n "$archive" ]]; then
    header_ok "$archive" scrypt || die "the identity archive is not a passphrase-encrypted age file"
  fi
  if (( test_mode )); then
    [[ -z "$archive" ]] || die "test mode cannot prompt for an identity-archive passphrase"
    identity="${RECOVERY_MATERIAL_TEST_IDENTITY:-}"
    [[ -f "$identity" ]] || die "test mode needs RECOVERY_MATERIAL_TEST_IDENTITY"
  else
    [[ -n "$archive" ]] || die "verify needs --identity-archive"
    { : </dev/tty; } 2>/dev/null || die "no terminal is available for the passphrase prompt"
    ! swap_active || die "swap is active; disable it (swapoff -a) before decrypting"
  fi

  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if (( test_mode )); then
    use_test_tmpdir
  else
    mount_private_tmpfs "$mib"
    install -m 0600 -- "$archive" "${work}/identity-archive.age"
    identity="${work}/identity-archive.age"
  fi

  # The output is inside the private directory, which nothing else can write to.
  if ! age -d -i "$identity" -o "${work}/plain" -- "$ciphertext" </dev/null; then
    printf 'item: %s\n' "$item"
    printf 'result: ERROR\n'
    die "age decryption failed"
  fi

  local rc result
  set +e
  cmp -s -- "${work}/plain" "$src"
  rc=$?
  set -e
  case "$rc" in
    0) result="MATCH" ;;
    1) result="DIFFER" ;;
    *) result="ERROR" ;;
  esac
  rm -f -- "${work}/plain"

  printf 'item: %s\n' "$item"
  printf 'source check: %s\n' "$source_report"
  printf 'ciphertext sha256: %s\n' "$(ciphertext_sha256 "$ciphertext")"
  printf 'private tmpfs: %s MiB\n' "$mib"
  printf 'cmp -s exit status: %s\n' "$rc"
  printf 'result: %s\n' "$result"
  [[ "$rc" -eq 0 ]]
}

# start-run and cleanup act on the operator's own files and never need root.
refuse_root() {
  [[ "$(id -u)" -ne 0 ]] || die "run this subcommand as yourself, not as root or through sudo"
}

# An absolute path with no empty, "." or ".." component and no trailing slash.
normalized_path() {
  [[ "$1" =~ ^(/[^/]+)+$ && "${1}/" != */./* && "${1}/" != */../* ]]
}

# The only names a run creates or transports: ITEM.age, ITEM.downloaded.age and
# the transported identity-archive.age.
run_file_name_ok() {
  local name="$1" known
  [[ "$name" == "identity-archive.age" ]] && return 0
  for known in "${ITEMS[@]}"; do
    [[ "$name" == "${known}.age" || "$name" == "${known}.downloaded.age" ]] && return 0
  done
  return 1
}

# Device and inode, link count, size, modification time and ciphertext SHA-256 of a
# kept file, compared before and after a cleanup. Never printed.
keep_fingerprint() {
  printf '%s %s' "$(stat -c '%d:%i %h %s %y' -- "$1")" "$(ciphertext_sha256 "$1")"
}

cmd_start_run() {
  local dir="" parent
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --dir) dir="$2" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done
  [[ -n "$dir" ]] || die "start-run needs --dir"
  refuse_root
  normalized_path "$dir" || die "the run directory must be an absolute, normalized path: ${dir}"
  [[ ! -e "$dir" && ! -L "$dir" ]] || die "the run directory already exists: ${dir}"
  parent="${dir%/*}"
  [[ -d "$parent" && ! -L "$parent" ]] || die "the parent directory does not exist or is a symbolic link: ${parent}"
  [[ "$(realpath -e -- "$parent")" == "$parent" ]] || die "the parent directory path contains a symbolic link: ${parent}"
  # mkdir without -p fails if the name exists in any form, including one created since the check.
  mkdir -m 0700 -- "$dir" || die "could not create the run directory: ${dir}"
  (set -C; : >"${dir}/${RUN_MARKER}") || die "could not create the run marker in ${dir}"
  printf 'run directory: %s\n' "$dir"
  printf 'result: PASS\n'
}

# Removes the named run files, the marker and the run directory, and nothing else.
# Every check runs before the first removal, so a refusal removes nothing.
cmd_cleanup() {
  local dir="" marker name entry path mode owner failed=0 i
  local -a remove=() keep=() fingerprints=()
  local -A listed=()
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --dir) dir="$2" ;;
      --remove) remove+=("$2") ;;
      --keep) keep+=("$2") ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done
  [[ -n "$dir" ]] || die "cleanup needs --dir"
  refuse_root
  normalized_path "$dir" || die "the run directory must be an absolute, normalized path: ${dir}"
  [[ -d "$dir" && ! -L "$dir" ]] || die "the run directory does not exist or is a symbolic link: ${dir}"
  [[ "$(realpath -e -- "$dir")" == "$dir" ]] || die "the run directory path contains a symbolic link: ${dir}"
  read -r mode owner < <(stat -c '%a %u' -- "$dir")
  [[ "$mode $owner" == "700 $(id -u)" ]] || die "the run directory must be mode 700 and owned by you: ${dir}"
  marker="${dir}/${RUN_MARKER}"
  [[ -f "$marker" && ! -L "$marker" ]] || die "not a run directory (no ${RUN_MARKER} from start-run): ${dir}"
  [[ "$(stat -c '%u %h' -- "$marker")" == "$(id -u) 1" ]] || die "the run marker is not yours or has other links: ${marker}"

  for name in "${remove[@]}"; do
    run_file_name_ok "$name" || die "not a run file name (ITEM.age, ITEM.downloaded.age or identity-archive.age): ${name}"
    [[ -z "${listed[$name]:-}" ]] || die "run file listed more than once: ${name}"
    listed[$name]=1
    path="${dir}/${name}"
    [[ ! -L "$path" ]] || die "run file is a symbolic link: ${path}"
    [[ -f "$path" ]] || die "run file does not exist or is not a regular file: ${path}"
    [[ "$(stat -c '%u %h' -- "$path")" == "$(id -u) 1" ]] || die "run file is not yours or has other hard links: ${path}"
    [[ ! "$path" -ot "$marker" ]] || die "run file predates the run directory, so this run did not create it: ${path}"
  done

  for path in "${keep[@]}"; do
    normalized_path "$path" || die "a kept file must be an absolute, normalized path: ${path}"
    [[ "$path" != "${dir}/"* ]] || die "a kept file must not be inside the run directory: ${path}"
    [[ -f "$path" && ! -L "$path" ]] || die "kept file does not exist, is not a regular file, or is a symbolic link: ${path}"
    [[ "$(realpath -e -- "$path")" == "$path" ]] || die "the kept file path contains a symbolic link: ${path}"
    fingerprints+=("$(keep_fingerprint "$path")")
  done

  # The directory must hold exactly the marker and the listed run files.
  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$RUN_MARKER" || -n "${listed[$entry]:-}" ]] || die "unexpected entry in the run directory; nothing was removed: ${dir}/${entry}"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\0')

  for name in "${remove[@]}"; do
    path="${dir}/${name}"
    if rm -f -- "$path" && [[ ! -e "$path" && ! -L "$path" ]]; then
      printf 'removed: %s\n' "$path"
    else
      printf 'ERROR: could not remove %s\n' "$path" >&2
      failed=1
    fi
  done
  if (( ! failed )) && ! { rm -f -- "$marker" && rmdir -- "$dir"; }; then
    failed=1
  fi
  if [[ -e "$dir" || -L "$dir" ]]; then
    printf 'ERROR: the run directory is still present: %s\n' "$dir" >&2
    failed=1
  else
    printf 'run directory: absent\n'
  fi
  for i in "${!keep[@]}"; do
    if [[ -f "${keep[$i]}" && ! -L "${keep[$i]}" && "$(keep_fingerprint "${keep[$i]}")" == "${fingerprints[$i]}" ]]; then
      printf 'retained unchanged: %s\n' "${keep[$i]}"
    else
      printf 'ERROR: a kept file is missing or changed: %s\n' "${keep[$i]}" >&2
      failed=1
    fi
  done
  if (( failed )); then
    printf 'result: ERROR\n'
    return 1
  fi
  printf 'result: PASS\n'
}

sha256_ok() {
  [[ "${1,,}" =~ ^[0-9a-f]{64}$ ]]
}

# A file decrypt-inventory only reads: absolute, normalized, outside the inventory
# directory, and a regular file with no symbolic link anywhere in its path.
check_input_file() {
  local label="$1" path="$2" dir="$3"
  normalized_path "$path" || die "the ${label} path must be absolute and normalized: ${path}"
  [[ "$path" != "${dir}/"* ]] || die "the ${label} must not be inside the inventory directory: ${path}"
  [[ ! -L "$path" ]] || die "the ${label} is a symbolic link: ${path}"
  [[ -f "$path" ]] || die "the ${label} does not exist or is not a regular file: ${path}"
  [[ "$(realpath -e -- "$path")" == "$path" ]] || die "the ${label} path contains a symbolic link: ${path}"
}

decrypt_dir="" decrypt_done=0
# Removes the private copies, and the previous plaintext unless it was decrypted and
# checked, including on error and on INT, TERM and HUP.
decrypt_cleanup() {
  local status=$? failed=0 name
  if [[ -n "$decrypt_dir" ]]; then
    for name in "$PREVIOUS_COPY" "$ARCHIVE_COPY"; do
      rm -f -- "${decrypt_dir}/${name}" 2>/dev/null || failed=1
      [[ ! -e "${decrypt_dir}/${name}" ]] || failed=1
    done
    if (( ! decrypt_done )); then
      rm -f -- "${decrypt_dir}/${PREVIOUS_PLAINTEXT}" 2>/dev/null || failed=1
      [[ ! -e "${decrypt_dir}/${PREVIOUS_PLAINTEXT}" ]] || failed=1
    fi
  fi
  if (( failed )); then
    printf 'ERROR: cleanup of %s failed; remove its decryption files before continuing\n' "$decrypt_dir" >&2
    (( status != 0 )) || status=1
  fi
  exit "$status"
}

cmd_decrypt_inventory() {
  local dir="" ciphertext_in="" cipher_sum="" archive_in="" archive_sum="" name mode owner identity out
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --inventory-dir) dir="$2" ;;
      --ciphertext) ciphertext_in="$2" ;;
      --ciphertext-sha256) cipher_sum="$2" ;;
      --identity-archive) archive_in="$2" ;;
      --archive-sha256) archive_sum="$2" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done
  [[ -n "$dir" && -n "$ciphertext_in" && -n "$cipher_sum" && -n "$archive_in" && -n "$archive_sum" ]] \
    || die "decrypt-inventory needs --inventory-dir, --ciphertext, --ciphertext-sha256, --identity-archive and --archive-sha256"
  refuse_root
  require_age
  refuse_passphrase_env
  sha256_ok "$cipher_sum" || die "--ciphertext-sha256 must be 64 hexadecimal characters"
  sha256_ok "$archive_sum" || die "--archive-sha256 must be 64 hexadecimal characters"

  normalized_path "$dir" || die "the inventory directory must be an absolute, normalized path: ${dir}"
  [[ -d "$dir" && ! -L "$dir" ]] || die "the inventory directory does not exist or is a symbolic link: ${dir}"
  [[ "$(realpath -e -- "$dir")" == "$dir" ]] || die "the inventory directory path contains a symbolic link: ${dir}"
  read -r mode owner < <(stat -c '%a %u' -- "$dir")
  [[ "$mode $owner" == "700 $(id -u)" ]] || die "the inventory directory must be mode 700 and owned by you: ${dir}"
  if (( ! test_mode )); then
    [[ "$(findmnt -no FSTYPE --mountpoint "$dir" 2>/dev/null)" == "tmpfs" ]] \
      || die "the inventory directory is not a tmpfs mount point; create it as in the runbook first: ${dir}"
    ! swap_active || die "swap is active; disable it before decrypting"
    { : </dev/tty; } 2>/dev/null || die "no terminal is available for the passphrase prompt"
  fi
  for name in "$PREVIOUS_PLAINTEXT" "$PREVIOUS_COPY" "$ARCHIVE_COPY" "$REPLACEMENT_NAME"; do
    [[ ! -e "${dir}/${name}" && ! -L "${dir}/${name}" ]] || die "already present in the inventory directory: ${dir}/${name}"
  done
  check_input_file "previous inventory ciphertext" "$ciphertext_in" "$dir"
  check_input_file "identity archive" "$archive_in" "$dir"
  if (( test_mode )); then
    identity="${RECOVERY_MATERIAL_TEST_IDENTITY:-}"
    [[ -f "$identity" ]] || die "test mode needs RECOVERY_MATERIAL_TEST_IDENTITY"
  else
    identity="${dir}/${ARCHIVE_COPY}"
  fi

  trap decrypt_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  decrypt_dir="$dir"
  # The checks apply to the private copies that age reads; the originals are only read.
  install -m 0600 -- "$ciphertext_in" "${dir}/${PREVIOUS_COPY}" || die "could not copy the previous inventory ciphertext"
  [[ "$(ciphertext_sha256 "${dir}/${PREVIOUS_COPY}")" == "${cipher_sum,,}" ]] \
    || die "the previous inventory ciphertext does not have the expected SHA-256"
  header_ok "${dir}/${PREVIOUS_COPY}" X25519 || die "the previous inventory ciphertext header check failed"
  install -m 0600 -- "$archive_in" "${dir}/${ARCHIVE_COPY}" || die "could not copy the identity archive"
  [[ "$(ciphertext_sha256 "${dir}/${ARCHIVE_COPY}")" == "${archive_sum,,}" ]] \
    || die "the identity archive does not have the expected SHA-256"
  header_ok "${dir}/${ARCHIVE_COPY}" scrypt || die "the identity archive is not a passphrase-encrypted age file"

  out="${dir}/${PREVIOUS_PLAINTEXT}"
  age -d -i "$identity" -o "$out" -- "${dir}/${PREVIOUS_COPY}" </dev/null || die "age decryption failed"
  [[ -f "$out" && ! -L "$out" && -s "$out" ]] || die "the decrypted previous inventory is missing, empty or not a regular file"
  [[ "$(stat -c '%a %u %h' -- "$out")" == "600 $(id -u) 1" ]] \
    || die "the decrypted previous inventory is not mode 600, yours and singly linked"
  python3 "${script_dir}/validate-recovery-material.py" --check-inventory "$out" >/dev/null \
    || die "the previous inventory failed the inventory check; it was removed"
  decrypt_done=1

  printf 'item: recovery-inventory\n'
  printf 'previous ciphertext: PASS (expected SHA-256, regular file, no link, one X25519 stanza)\n'
  printf 'identity archive: PASS (expected SHA-256, regular file, no link, one scrypt stanza)\n'
  printf 'previous inventory: %s (mode 600, nonempty, inventory check PASS)\n' "$out"
  printf 'result: PASS\n'
}

main() {
  local command="${1:-}"
  (( $# )) && shift
  case "$command" in
    check-recipient) cmd_check_recipient ;;
    encrypt) cmd_encrypt "$@" ;;
    verify) cmd_verify "$@" ;;
    start-run) cmd_start_run "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    decrypt-inventory) cmd_decrypt_inventory "$@" ;;
    *) die "usage: recovery-material.sh {check-recipient|encrypt|verify|start-run|cleanup|decrypt-inventory} [options]" ;;
  esac
}

main "$@"
