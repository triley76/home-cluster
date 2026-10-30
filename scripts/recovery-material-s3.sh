#!/usr/bin/env bash
# Stage 2 S3 helper for recovery-material ciphertext, run on the administrative
# workstation (WSL) with the routine HomeClusterBackupOperator IAM Identity Center
# profile. It handles ciphertext only and never decrypts anything.
#
# Subcommands:
#   check-role
#       Confirm the session is the HomeClusterBackupOperator role. Prints PASS or FAIL.
#   upload --item ITEM --date YYYY-MM-DD --file FILE.age [--receipt FILE]
#          [--ciphertext-sha256 HEX] [--new-version --replaces-sha256 HEX]
#       Upload to recovery/ITEM/DATE.age with an S3-verified SHA-256 checksum.
#       With --ciphertext-sha256 (required for stage3-p2-snapshot), FILE must have
#       that SHA-256, so an incomplete or different transfer is refused before
#       anything is sent.
#       Refuses an existing key. --new-version adds a version to an existing key
#       deliberately (for example a same-date inventory update). It requires
#       --replaces-sha256, the ciphertext SHA-256 of the version being replaced,
#       which must equal S3's stored checksum of the current version, and --receipt,
#       so that the new version is pinned. It is refused for a key that does not exist.
#       With --receipt, the object key and version ID are written to a new private
#       receipt file instead of being printed.
#   download --item ITEM --date YYYY-MM-DD (--version-id ID | --receipt FILE)
#            --out FILE.age --compare-with FILE.age
#       Download that exact version into the helper's private work directory,
#       validate it, copy it exclusively to --out, and compare it with the uploaded
#       file using cmp -s. With --receipt, the version ID is read from the receipt,
#       which must name the same object key, and is not printed.
#
# Items: k3s-server-token, grafana-admin, recovery-inventory, encryption-config,
# stage3-p2-snapshot.
# encryption-config (the K3s secrets-encryption configuration) and
# stage3-p2-snapshot (the interim manual copy of the Stage 3 p2 etcd snapshot, kept
# under recovery/ and separate from Stage 4's K3s uploads under etcd/) require
# --receipt for both upload and download, so their version IDs are never printed.
# stage3-p2-snapshot also requires --ciphertext-sha256 on upload, and a ciphertext
# of at most 65 MiB (the helper's 64 MiB snapshot cap plus age's overhead).
#
# A receipt is a mode 600 file holding two lines, "key: <object key>" and
# "version id: <version ID>", in a directory owned by the operator with no group
# or other access (the inventory tmpfs). upload creates it exclusively, with a
# hard link that never replaces, follows or opens an existing path.
#
# The bucket name comes from HOME_CLUSTER_BACKUP_BUCKET, or from the 0600 file
# ~/.config/home-cluster/backup-bucket. It is never committed and never printed.
# The helper never prints the account ID or any ARN: a failed AWS call is reported
# by its error code only, and its raw error output is discarded. Static access-key
# and profile-override environment variables are refused, so only the SSO profile
# is used.
#
# Requires: bash, AWS CLI v2 signed in to the home-cluster-backup-operator
# profile, coreutils (sha256sum, base64), cmp.
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

PROFILE="home-cluster-backup-operator"
REGION="us-east-1"
ITEMS=(k3s-server-token grafana-admin recovery-inventory encryption-config stage3-p2-snapshot)
# Items whose version ID is kept in a receipt and never printed.
RECEIPT_ITEMS=(encryption-config stage3-p2-snapshot)
# The largest stage3-p2-snapshot ciphertext accepted.
SNAPSHOT_CIPHERTEXT_MAX_BYTES=$(( 65 * 1024 * 1024 ))

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

work=""
cleanup() {
  local status=$?
  if [[ -n "$work" ]] && ! rm -rf -- "$work" 2>/dev/null; then
    printf 'ERROR: could not remove the work directory %s\n' "$work" >&2
    (( status != 0 )) || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
work="$(mktemp -d)"
[[ "$(stat -c '%a %u' -- "$work")" == "700 $(id -u)" ]] || die "the work directory is not private"

for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE; do
  [[ -z "${!name:-}" ]] || die "${name} is set; unset it so only the ${PROFILE} profile is used"
done
command -v aws >/dev/null 2>&1 || die "the AWS CLI is not installed"

require_item() {
  local item="$1" known
  for known in "${ITEMS[@]}"; do
    [[ "$item" == "$known" ]] && return 0
  done
  die "unknown item: ${item} (expected one of: ${ITEMS[*]})"
}

receipt_item() {
  local known
  for known in "${RECEIPT_ITEMS[@]}"; do
    [[ "$1" == "$known" ]] && return 0
  done
  return 1
}

# The receipt directory must be a real directory owned by the operator, with no
# group or other access.
check_receipt_dir() {
  local dir="$1" owner mode
  [[ -d "$dir" && ! -L "$dir" ]] || die "the receipt directory does not exist or is a symbolic link"
  read -r owner mode < <(stat -c '%u %a' -- "$dir")
  [[ "$owner" == "$(id -u)" ]] || die "the receipt directory is not owned by the operator"
  (( (8#${mode} & 8#077) == 0 )) || die "the receipt directory is accessible to group or others (mode ${mode})"
}

# Reads the version ID from a receipt for the current key. Neither value is printed.
read_receipt() {
  local file="$1" mode owner line1 line2
  [[ -f "$file" && ! -L "$file" ]] || die "the receipt is missing, not a regular file, or a symbolic link"
  check_receipt_dir "$(dirname -- "$file")"
  read -r mode owner < <(stat -c '%a %u' -- "$file")
  [[ "$owner" == "$(id -u)" ]] || die "the receipt is not owned by the operator"
  [[ "$mode" == "600" || "$mode" == "400" ]] || die "the receipt must be mode 600 or 400"
  [[ "$(wc -l < "$file")" -eq 2 ]] || die "the receipt is malformed"
  { IFS= read -r line1 && IFS= read -r line2; } <"$file" || die "the receipt is malformed"
  # Exactly those two LF-terminated lines, with nothing after them.
  [[ "$(wc -c < "$file")" -eq $(( ${#line1} + ${#line2} + 2 )) ]] || die "the receipt is malformed"
  [[ "$line1" == "key: ${key}" ]] || die "the receipt is for a different object key"
  [[ "$line2" == "version id: "* ]] || die "the receipt is malformed"
  version_id="${line2#version id: }"
  line2=""
  version_ok "$version_id" || die "the receipt holds no usable version ID"
}

# Creates the receipt exclusively: the content goes to a new private file from
# mktemp (O_EXCL, mode 600) in the same directory, which is then hard-linked to the
# receipt name. link(2) fails if the name exists in any form (file, symbolic link,
# FIFO or device) and never follows or opens it, unlike a noclobber redirection,
# which opens an existing non-regular file. The temporary name is always removed.
write_receipt() {
  local file="$1" version="$2" staged status=0
  staged="$(mktemp -- "$(dirname -- "$file")/.receipt.XXXXXX")" || return 1
  printf 'key: %s\nversion id: %s\n' "$key" "$version" >"$staged" || status=1
  if (( status == 0 )); then
    ln -- "$staged" "$file" 2>/dev/null || status=1
  fi
  rm -f -- "$staged" || status=1
  return "$status"
}

load_bucket() {
  local file="${HOME}/.config/home-cluster/backup-bucket" mode
  if [[ -n "${HOME_CLUSTER_BACKUP_BUCKET:-}" ]]; then
    bucket="$HOME_CLUSTER_BACKUP_BUCKET"
  else
    [[ -f "$file" && ! -L "$file" ]] || die "set HOME_CLUSTER_BACKUP_BUCKET or create ${file}"
    mode="$(stat -c '%a' -- "$file")"
    [[ "$mode" == "600" || "$mode" == "400" ]] || die "${file} must be mode 600 or 400"
    bucket="$(head -n 1 -- "$file" | tr -d '\r\n ')"
  fi
  [[ "$bucket" =~ ^home-cluster-backup-[a-z0-9]{8,32}$ ]] \
    || die "the configured bucket name does not match the expected pattern"
}

aws_cli() {
  AWS_PAGER="" aws --profile "$PROFILE" --region "$REGION" --no-cli-pager --no-cli-auto-prompt "$@"
}

error_code() {
  grep -Eo 'An error occurred \([A-Za-z0-9.]+\)' "${work}/aws.err" | head -n 1 | sed -E 's/.*\((.*)\)/\1/' || true
}

# Runs one AWS CLI call. Standard output passes through; on failure only the
# error code is reported, and the raw error text is discarded either way.
aws_call() {
  local rc code
  set +e
  aws_cli "$@" 2>"${work}/aws.err"
  rc=$?
  set -e
  if (( rc != 0 )); then
    code="$(error_code)"
    : >"${work}/aws.err"
    printf 'ERROR: AWS %s %s failed: %s\n' "$1" "$2" "${code:-no error code; output suppressed}" >&2
    return "$rc"
  fi
  : >"${work}/aws.err"
}

cmd_check_role() {
  local arn
  arn="$(aws_call sts get-caller-identity --query Arn --output text)" || { echo "FAIL"; return 1; }
  if [[ "$arn" =~ ^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_HomeClusterBackupOperator_[0-9a-f]+/[^/[:space:]]+$ ]]; then
    arn=""
    echo "PASS"
  else
    arn=""
    echo "FAIL"
    return 1
  fi
}

require_role() {
  cmd_check_role >/dev/null || die "the session is not the HomeClusterBackupOperator role; sign in with: aws sso login --profile ${PROFILE}"
}

# Same header check as recovery-material.sh: version line, one X25519 stanza, MAC line.
header_ok() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  LC_ALL=C awk '
    NR == 1 { if ($0 != "age-encryption.org/v1") { bad = 1; exit } next }
    /^-> / { stanzas++; if ($2 != "X25519") bad = 1; next }
    /^--- / { mac = 1; exit }
    NR > 64 { bad = 1; exit }
    END { exit (bad || !mac || stanzas != 1) ? 1 : 0 }
  ' "$file"
}

sha256_hex() {
  sha256sum -- "$1" | cut -d' ' -f1
}

# The digest bytes never pass through a shell variable: the variable holds only
# "\xHH" text, and printf %b writes the raw bytes, including zero bytes, to the pipe.
hex_base64() {
  printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')" | base64 -w 0
}

sha256_base64() {
  hex_base64 "$(sha256_hex "$1")"
}

sha256_ok() {
  [[ "${1,,}" =~ ^[0-9a-f]{64}$ ]]
}

# S3's stored SHA-256 checksum (base64) of the key's current version.
current_checksum() {
  aws_call s3api head-object --bucket "$bucket" --key "$key" --checksum-mode ENABLED \
    --query ChecksumSHA256 --output text
}

# Copies $1 to $2, creating $2 exclusively (noclobber, O_EXCL) on descriptor 3 and
# writing only through that descriptor, so an existing path is never overwritten or
# followed. The created file's device and inode are recorded before any data is
# written. If the copy fails, the output is removed only when it is still that same
# regular, non-symlink file; a pre-existing path is never removed.
copy_exclusive() {
  local ciphertext="$1" dst="$2" ours="" removed=0
  rm -f -- "${work}/created"
  if ( set -C; { stat -L -c '%d:%i' /dev/fd/3 >"${work}/created" && cat -- "$ciphertext" >&3; } 3>"$dst" ) 2>/dev/null; then
    return 0
  fi
  [[ -s "${work}/created" ]] && ours="$(<"${work}/created")"
  if [[ -z "$ours" ]]; then
    die "could not create ${dst} exclusively; any existing path was left unchanged"
  fi
  if [[ -f "$dst" && ! -L "$dst" && "$(stat -c '%d:%i' -- "$dst" 2>/dev/null)" == "$ours" ]]; then
    rm -f -- "$dst" && removed=1
  fi
  if (( removed )); then
    die "copying the download to ${dst} failed; the partial output was removed"
  fi
  die "copying the download to ${dst} failed; the path no longer matches the file this run created, so it was not removed"
}

version_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,1024}$ && "$1" != "None" && "$1" != "null" ]]
}

object_key() {
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD"
  key="recovery/${item}/${date}.age"
}

# Exit status 0 if the key exists, 1 if it does not; any other error stops the helper.
object_exists() {
  local rc code
  set +e
  aws_cli s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>"${work}/aws.err"
  rc=$?
  set -e
  code="$(error_code)"
  : >"${work}/aws.err"
  if (( rc == 0 )); then
    return 0
  elif [[ "$code" == "404" || "$code" == "NoSuchKey" || "$code" == "NotFound" ]]; then
    return 1
  fi
  die "AWS s3api head-object failed: ${code:-no error code; output suppressed}"
}

parse_args() {
  item="" date="" file="" version_id="" out="" compare="" receipt="" new_version=0
  expected_sha256="" replaces_sha256=""
  while (( $# )); do
    if [[ "$1" == "--new-version" ]]; then
      new_version=1
      shift
      continue
    fi
    [[ "$1" == --* && $# -ge 2 ]] || die "missing value for argument: $1"
    case "$1" in
      --item) item="$2" ;;
      --date) date="$2" ;;
      --file) file="$2" ;;
      --version-id) version_id="$2" ;;
      --out) out="$2" ;;
      --compare-with) compare="$2" ;;
      --receipt) receipt="$2" ;;
      --ciphertext-sha256) expected_sha256="$2" ;;
      --replaces-sha256) replaces_sha256="$2" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift 2
  done
}

cmd_upload() {
  parse_args "$@"
  [[ -n "$item" && -n "$date" && -n "$file" ]] || die "upload needs --item, --date and --file"
  require_item "$item"
  object_key
  if receipt_item "$item"; then
    [[ -n "$receipt" ]] || die "${item} upload needs --receipt, so its version ID is not printed"
  fi
  if [[ "$item" == "stage3-p2-snapshot" ]]; then
    [[ -n "$expected_sha256" ]] || die "${item} upload needs --ciphertext-sha256, the SHA-256 that encrypt printed"
  fi
  if (( new_version )); then
    [[ -n "$replaces_sha256" ]] || die "--new-version needs --replaces-sha256, the ciphertext SHA-256 of the version it replaces"
    [[ -n "$receipt" ]] || die "--new-version needs --receipt, so the new version is pinned"
    sha256_ok "$replaces_sha256" || die "--replaces-sha256 must be 64 hexadecimal characters"
  else
    [[ -z "$replaces_sha256" ]] || die "--replaces-sha256 is only valid with --new-version"
  fi
  if [[ -n "$receipt" ]]; then
    [[ ! -e "$receipt" && ! -L "$receipt" ]] || die "the receipt already exists: ${receipt}"
    check_receipt_dir "$(dirname -- "$receipt")"
  fi
  header_ok "$file" || die "the file is not a single-recipient X25519 age ciphertext"
  if [[ -n "$expected_sha256" ]]; then
    sha256_ok "$expected_sha256" || die "--ciphertext-sha256 must be 64 hexadecimal characters"
    [[ "$(sha256_hex "$file")" == "${expected_sha256,,}" ]] \
      || die "the file does not have the expected SHA-256 (incomplete or different transfer); nothing was uploaded"
  fi
  if [[ "$item" == "stage3-p2-snapshot" ]]; then
    (( $(wc -c < "$file") <= SNAPSHOT_CIPHERTEXT_MAX_BYTES )) || die "the ${item} ciphertext exceeds 65 MiB"
  fi
  load_bucket
  require_role

  if object_exists; then
    (( new_version )) || die "${key} already exists; pass --new-version with --replaces-sha256 to add a new version deliberately"
    local current
    current="$(current_checksum)" || die "could not read the current version's checksum"
    [[ -n "$current" && "$current" != "None" ]] \
      || die "the current version of ${key} has no stored SHA-256 checksum, so the version it replaces cannot be confirmed"
    [[ "$current" == "$(hex_base64 "${replaces_sha256,,}")" ]] \
      || die "the current version of ${key} does not have the SHA-256 given with --replaces-sha256; nothing was uploaded"
  elif (( new_version )); then
    die "${key} does not exist; --new-version only adds a version to an existing key"
  fi

  local checksum version
  checksum="$(sha256_base64 "$file")"
  version="$(aws_call s3api put-object --bucket "$bucket" --key "$key" --body "$file" \
    --checksum-algorithm SHA256 --checksum-sha256 "$checksum" \
    --query VersionId --output text)" || die "upload failed"
  version_ok "$version" || die "S3 returned no usable version ID; versioning may not be enabled"

  printf 'key: %s\n' "$key"
  if [[ -n "$receipt" ]]; then
    if ! write_receipt "$receipt" "$version"; then
      version=""
      die "the upload succeeded but the receipt could not be written; treat the new version as unverified and do not use it"
    fi
    version=""
    printf 'version receipt: %s\n' "$receipt"
  else
    printf 'version id: %s\n' "$version"
  fi
  printf 'ciphertext bytes: %s\n' "$(wc -c < "$file")"
  printf 'ciphertext sha256: %s\n' "$(sha256_hex "$file")"
}

cmd_download() {
  parse_args "$@"
  [[ -n "$item" && -n "$date" && -n "$out" && -n "$compare" ]] \
    || die "download needs --item, --date, --version-id or --receipt, --out and --compare-with"
  [[ -n "$version_id" && -z "$receipt" || -z "$version_id" && -n "$receipt" ]] \
    || die "download needs exactly one of --version-id and --receipt"
  require_item "$item"
  object_key
  if receipt_item "$item"; then
    [[ -n "$receipt" ]] || die "${item} download needs --receipt, so its version ID is not printed"
  fi
  if [[ -n "$receipt" ]]; then
    read_receipt "$receipt"
  fi
  version_ok "$version_id" || die "--version-id has unexpected characters"
  [[ ! -e "$out" && ! -L "$out" ]] || die "output already exists: ${out}"
  header_ok "$compare" || die "--compare-with is not a single-recipient X25519 age ciphertext"
  load_bucket
  require_role

  # Downloaded into the private work directory first; nothing reaches --out unless
  # the version and header checks pass.
  local staged="${work}/download.age" returned
  returned="$(aws_call s3api get-object --bucket "$bucket" --key "$key" --version-id "$version_id" \
    --checksum-mode ENABLED "$staged" --query VersionId --output text)" || die "download failed"
  [[ "$returned" == "$version_id" ]] || die "S3 returned a different version than requested"
  header_ok "$staged" || die "the downloaded object is not a single-recipient X25519 age ciphertext"
  copy_exclusive "$staged" "$out"

  local rc result
  set +e
  cmp -s -- "$out" "$compare"
  rc=$?
  set -e
  case "$rc" in
    0) result="MATCH" ;;
    1) result="DIFFER" ;;
    *) result="ERROR" ;;
  esac

  printf 'key: %s\n' "$key"
  if [[ -n "$receipt" ]]; then
    printf 'version id: as recorded in the receipt\n'
  else
    printf 'version id: %s\n' "$version_id"
  fi
  printf 'downloaded sha256: %s\n' "$(sha256_hex "$out")"
  printf 'uploaded sha256: %s\n' "$(sha256_hex "$compare")"
  printf 'cmp -s exit status: %s\n' "$rc"
  printf 'result: %s\n' "$result"
  [[ "$rc" -eq 0 ]]
}

main() {
  local command="${1:-}"
  (( $# )) && shift
  case "$command" in
    check-role) cmd_check_role ;;
    upload) cmd_upload "$@" ;;
    download) cmd_download "$@" ;;
    *) die "usage: recovery-material-s3.sh {check-role|upload|download} [options]" ;;
  esac
}

main "$@"
