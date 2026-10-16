#!/usr/bin/env bash
# Stage 2 S3 helper for recovery-material ciphertext, run on the administrative
# workstation (WSL) with the routine HomeClusterBackupOperator IAM Identity Center
# profile. It handles ciphertext only and never decrypts anything.
#
# Subcommands:
#   check-role
#       Confirm the session is the HomeClusterBackupOperator role. Prints PASS or FAIL.
#   upload --item ITEM --date YYYY-MM-DD --file FILE.age [--new-version]
#       Upload to recovery/ITEM/DATE.age with an S3-verified SHA-256 checksum.
#       Refuses to add a version to an existing key unless --new-version is given.
#   download --item ITEM --date YYYY-MM-DD --version-id ID --out FILE.age --compare-with FILE.age
#       Download that exact version into the helper's private work directory,
#       validate it, copy it exclusively to --out, and compare it with the uploaded
#       file using cmp -s.
#
# Items: k3s-server-token, grafana-admin, recovery-inventory.
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
ITEMS=(k3s-server-token grafana-admin recovery-inventory)

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
sha256_base64() {
  printf '%b' "$(sha256_hex "$1" | sed 's/../\\x&/g')" | base64 -w 0
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
  item="" date="" file="" version_id="" out="" compare="" new_version=0
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
  header_ok "$file" || die "the file is not a single-recipient X25519 age ciphertext"
  load_bucket
  require_role

  if object_exists && (( ! new_version )); then
    die "${key} already exists; pass --new-version to add a new version deliberately"
  fi

  local checksum version
  checksum="$(sha256_base64 "$file")"
  version="$(aws_call s3api put-object --bucket "$bucket" --key "$key" --body "$file" \
    --checksum-algorithm SHA256 --checksum-sha256 "$checksum" \
    --query VersionId --output text)" || die "upload failed"
  version_ok "$version" || die "S3 returned no usable version ID; versioning may not be enabled"

  printf 'key: %s\n' "$key"
  printf 'version id: %s\n' "$version"
  printf 'ciphertext sha256: %s\n' "$(sha256_hex "$file")"
}

cmd_download() {
  parse_args "$@"
  [[ -n "$item" && -n "$date" && -n "$version_id" && -n "$out" && -n "$compare" ]] \
    || die "download needs --item, --date, --version-id, --out and --compare-with"
  require_item "$item"
  object_key
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
  printf 'version id: %s\n' "$version_id"
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
