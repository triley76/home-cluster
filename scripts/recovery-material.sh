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
#       Decrypt a downloaded ciphertext into a private tmpfs and compare it with the
#       source using cmp -s. Prints MATCH, DIFFER or ERROR and the cmp exit status.
#
# Items: k3s-server-token, grafana-admin, recovery-inventory, encryption-config.
# encryption-config is the K3s secrets-encryption configuration (Stage 3). Its
# --source must be exactly /var/lib/rancher/k3s/server/cred/encryption-config.json:
# no other path, alias or symbolic-link component, with a canonical path equal to
# it. The file must be owned by root:root, and its directory must be a real
# directory owned by root:root and not writable by group or others.
#
# Production runs as root (through sudo). The helper never prints plaintext,
# plaintext sizes or plaintext hashes; age reads the source file itself.
# encrypt creates the output exclusively (it never overwrites or follows an existing
# path), and under sudo writes it as the invoking user, so root never writes into the
# operator's directory. verify:
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
# These variables are refused outright outside test mode, so they can never
# override a production source path or owner.
# Test mode does NOT exercise sudo, runuser, the tmpfs mount, the swap check, the
# passphrase prompt, SSH, AWS or S3.
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
ITEMS=(k3s-server-token grafana-admin recovery-inventory encryption-config)
# Items whose source must be owned by root:root (uid 0, gid 0).
ROOT_OWNED_ITEMS=(encryption-config)
# The only production source of encryption-config.
ENCRYPTION_CONFIG_SOURCE="/var/lib/rancher/k3s/server/cred/encryption-config.json"
TEST_ONLY_VARIABLES=(RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE RECOVERY_MATERIAL_TEST_SOURCE_OWNER RECOVERY_MATERIAL_TEST_PARENT_OWNER)
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

# encryption-config only, before any other source check: the path must be exactly
# the expected one, no component of its directory may be a symbolic link, and the
# directory must be a root:root directory that group and others cannot write to.
# Metadata only.
check_bound_source() {
  local src="$1" expected parent prefix="" part mode owner
  local -a parts
  expected="$(expected_source)"
  [[ "$src" == "$expected" ]] || die "the encryption-config source must be exactly ${expected}"
  parent="${expected%/*}"
  IFS='/' read -r -a parts <<<"${parent#/}"
  for part in "${parts[@]}"; do
    prefix+="/${part}"
    [[ ! -L "$prefix" ]] || die "a directory in the source path is a symbolic link: ${prefix}"
  done
  [[ -e "$parent" ]] || die "the credential directory does not exist: ${parent}"
  [[ -d "$parent" ]] || die "the credential directory is not a directory: ${parent}"
  read -r mode owner < <(stat -c '%a %u:%g' -- "$parent")
  [[ "$owner" == "$(required_parent_owner)" ]] \
    || die "the credential directory is not owned by root:root (owner ${owner}): ${parent}"
  (( (8#${mode} & 8#022) == 0 )) \
    || die "the credential directory is writable by group or others (mode ${mode}): ${parent}"
}

# After the file checks: the canonical path of the existing file is the expected path.
check_canonical_source() {
  local src="$1" resolved
  resolved="$(realpath -e -- "$src")" || die "the source path could not be resolved: ${src}"
  [[ "$resolved" == "$(expected_source)" ]] \
    || die "the source path does not resolve to the expected path: ${src}"
}

# Metadata only (lstat and stat); the content is never read. Sets source_report, a
# line that is safe to print.
check_source() {
  local item="$1" src="$2" mode owner
  if [[ "$item" == "encryption-config" ]]; then
    check_bound_source "$src"
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
  fi
  source_report+=")"
}

# The output directory must be a real directory owned by the operator (or root) and
# not writable by group or others.
check_out_dir() {
  local dir="$1" owner mode operator
  [[ -d "$dir" && ! -L "$dir" ]] || die "output directory does not exist or is a symbolic link: ${dir}"
  read -r owner mode < <(stat -c '%u %a' -- "$dir")
  operator="$(id -u)"
  if (( ! test_mode )) && [[ -n "${SUDO_UID:-}" ]]; then
    operator="$SUDO_UID"
  fi
  [[ "$owner" == "$operator" || "$owner" == "0" ]] || die "output directory is not owned by the operator: ${dir}"
  (( (8#${mode} & 8#022) == 0 )) || die "output directory is writable by group or others (mode ${mode}): ${dir}"
}

ciphertext_sha256() {
  sha256sum -- "$1" | cut -d' ' -f1
}

parse_args() {
  item="" src="" out="" ciphertext="" archive=""
  while (( $# )); do
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --item) item="$2" ;;
      --source) src="$2" ;;
      --out) out="$2" ;;
      --ciphertext) ciphertext="$2" ;;
      --identity-archive) archive="$2" ;;
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
  local target="$1"
  if (( ! test_mode )) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    # $1 is expanded by the child shell, which receives "$target" as its first argument.
    # shellcheck disable=SC2016
    runuser -u "$SUDO_USER" -- bash -c 'umask 077; set -C; exec cat >"$1"' write_exclusive "$target"
  else
    (set -C; exec cat >"$target")
  fi
}

cmd_encrypt() {
  parse_args "$@"
  [[ -n "$item" && -n "$src" && -n "$out" ]] || die "encrypt needs --item, --source and --out"
  require_item "$item"
  [[ "$out" == *.age ]] || die "output must end in .age"
  [[ ! -e "$out" && ! -L "$out" ]] || die "output already exists: ${out}"
  require_root
  check_out_dir "$(dirname -- "$out")"
  require_age
  recipient_ok "$RECIPIENT_FILE" || die "the committed recipient failed validation"
  check_source "$item" "$src"

  local status=0
  age -R "$RECIPIENT_FILE" -- "$src" </dev/null | write_exclusive "$out" || status=$?
  if (( status != 0 )); then
    # Remove only a regular file this run may have created; never follow a link.
    [[ -f "$out" && ! -L "$out" ]] && rm -f -- "$out"
    die "age encryption or the exclusive write failed"
  fi
  if ! header_ok "$out" X25519; then
    rm -f -- "$out"
    die "the ciphertext header check failed"
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

mount_private_tmpfs() {
  local sources
  # Captured first: with pipefail, `findmnt | grep -q` can fail on SIGPIPE.
  sources="$(findmnt -rn -t tmpfs -o SOURCE)" || die "could not list tmpfs mounts"
  if grep -qx 'recovery-material' <<<"$sources"; then
    die "an earlier recovery-material tmpfs is still mounted; unmount it first (findmnt -t tmpfs -S recovery-material)"
  fi
  work="$(mktemp -d /run/recovery-material.XXXXXX)" || die "could not create the mount point"
  production_dir=1
  mount -t tmpfs -o size=4m,mode=0700,uid=0,gid=0,noexec,nosuid,nodev recovery-material "$work" \
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
  require_root
  require_age
  refuse_passphrase_env
  header_ok "$ciphertext" X25519 || die "the ciphertext header check failed"
  check_source "$item" "$src"

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
    mount_private_tmpfs
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
  printf 'cmp -s exit status: %s\n' "$rc"
  printf 'result: %s\n' "$result"
  [[ "$rc" -eq 0 ]]
}

main() {
  local command="${1:-}"
  (( $# )) && shift
  case "$command" in
    check-recipient) cmd_check_recipient ;;
    encrypt) cmd_encrypt "$@" ;;
    verify) cmd_verify "$@" ;;
    *) die "usage: recovery-material.sh {check-recipient|encrypt|verify} [options]" ;;
  esac
}

main "$@"
