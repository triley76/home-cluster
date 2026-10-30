#!/usr/bin/env bash
# Functional tests for scripts/recovery-material.sh and scripts/recovery-material-s3.sh.
#
# Group A: refusal paths, using a stub `age` that only reports its version.
# Group B: real encrypt and verify round trips with a throwaway identity generated
#          at runtime. Needs age and age-keygen v1.3.2; skipped when they are absent,
#          unless RECOVERY_MATERIAL_REQUIRE_AGE=1 (as in CI), which makes absence a failure.
# Group C: the S3 helper against a stub `aws` command.
# Group D: the encryption-config item (K3s secrets-encryption configuration) with a
#          synthetic configuration: source checks, refusals, interruption cleanup,
#          round trips (real age, as in group B) and receipt-based S3 transfers.
# Group E: start-run and the scoped cleanup, as in production (no test mode): a
#          retained prior ciphertext beside or copied into a run directory is never
#          removed, every refusal removes nothing, and mutants with a guard disabled
#          are caught.
# Group F: decrypt-inventory for an inventory update: decryption into the inventory
#          directory only (real age, as in group B), every refusal before decryption,
#          removal of the plaintext after a failure or TERM, the encrypt guard against
#          a leftover previous plaintext, an unchanged previous ciphertext, the tmpfs
#          gate outside test mode, and mutants with a guard disabled.
# Group G: stage3-p2-snapshot, the interim manual p2 snapshot copy, with a synthetic
#          snapshot directory and checkpoints file: source binding and substitution,
#          the checkpoint record, the 64 MiB cap, sudo and the ownership transition
#          (through a stub runuser that can damage the created file), substitution
#          during encryption (through an age wrapper), verify's expected SHA-256,
#          interrupted transfers, tmpfs sizing and the memory check, TERM cleanup,
#          receipts, collisions and explicit new versions in S3 (including a same-date
#          inventory update), the scoped cleanup of its run files, and mutants.
#
# Every run uses RECOVERY_MATERIAL_TEST=1 overrides or stubs. These tests do NOT
# exercise production sudo or the real runuser, the tmpfs mount, the swap check, the
# /dev/tty passphrase prompt, SSH, AWS or S3. Fixtures that look like secrets are
# assembled at runtime.
#
# Requires: bash, coreutils, python3; for group B, age and age-keygen v1.3.2.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/scripts/recovery-material.sh"
s3_helper="${repo_root}/scripts/recovery-material-s3.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
chmod 0700 "$tmp"

passed=0
failed=0
skipped=0
sentinel="PLAINTEXT-SENTINEL-$$-${RANDOM}${RANDOM}"
bech32="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
fake_recipient="age1${bech32}${bech32:0:26}"
fake_account="$(printf '%s%s%s' 4242 4242 4242)"
fake_bucket="home-cluster-backup-testfixture1"

pass() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# Values that no helper output may ever contain. Group D adds the synthetic
# encryption key, its key name and the synthetic plaintext's SHA-256.
never_print=("$sentinel" "$fake_account" "$fake_bucket")

# expect NAME STATUS MESSAGE -- COMMAND...: STATUS is "ok", "fail" or a number; MESSAGE
# must appear in the combined output (empty to skip). Output must never contain a
# never_print value, nor EXTRA_FORBIDDEN when it is set (a version ID that a case
# keeps in a receipt).
expect() {
  local name="$1" want="$2" message="$3" rc
  shift 4
  set +e
  "$@" >"${tmp}/out" 2>&1
  rc=$?
  set -e
  if [[ "$want" == "ok" && "$rc" -ne 0 ]] || [[ "$want" == "fail" && "$rc" -eq 0 ]] \
    || [[ "$want" =~ ^[0-9]+$ && "$rc" -ne "$want" ]]; then
    fail "$name" "exit status ${rc}, expected ${want}"
    sed 's/^/     | /' "${tmp}/out"
    return 0
  fi
  if [[ -n "$message" ]] && ! grep -qF -- "$message" "${tmp}/out"; then
    fail "$name" "expected output not found: ${message}"
    sed 's/^/     | /' "${tmp}/out"
    return 0
  fi
  if leaked "${tmp}/out"; then
    fail "$name" "output contained a value that must never be printed"
    return 0
  fi
  pass "$name"
}

leaked() {
  local value
  for value in "${never_print[@]}" ${EXTRA_FORBIDDEN:+"$EXTRA_FORBIDDEN"}; do
    grep -qF -- "$value" "$1" && return 0
  done
  return 1
}

fresh_dir() {
  local dir
  dir="$(mktemp -d "${tmp}/d.XXXXXX")"
  chmod 0700 "$dir"
  printf '%s' "$dir"
}

empty_dir() {
  [[ -z "$(ls -A -- "$1")" ]]
}

write_header() {
  # A syntactically valid age header with the given stanza types; the payload is junk.
  local file="$1"
  shift
  {
    printf 'age-encryption.org/v1\n'
    local type
    for type in "$@"; do
      printf -- '-> %s c3RhbnphYXJn\nYm9keQ\n' "$type"
    done
    printf -- '--- bWFj\n'
    printf '\001\002\003payload'
  } >"$file"
  chmod 0600 "$file"
}

# --- stubs --------------------------------------------------------------------
stub_age_dir="${tmp}/stub-age"
mkdir -p "$stub_age_dir"
cat >"${stub_age_dir}/age" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "${STUB_AGE_VERSION:-v1.3.2}"
  exit 0
fi
if [[ -n "${STUB_AGE_SLEEP_PIDFILE:-}" ]]; then
  out=""
  while (( $# )); do
    [[ "$1" == "-o" ]] && out="$2"
    shift
  done
  printf 'decrypted\n' >"$out"
  echo "$$" >"$STUB_AGE_SLEEP_PIDFILE"
  exec sleep 30
fi
echo "stub age: refusing real work" >&2
exit 1
EOF
chmod 0755 "${stub_age_dir}/age"

recipient_file="${tmp}/recipient.txt"
printf '%s\n' "$fake_recipient" >"$recipient_file"

source_file="${tmp}/source"
printf '%s\n' "$sentinel" >"$source_file"
chmod 0600 "$source_file"

run_test_mode() {
  env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="$recipient_file" "$@"
}

# --- group A: refusals ----------------------------------------------------------
echo "Group A: refusal paths (stub age)"
stub_path="${stub_age_dir}:${PATH}"

expect "tracing is refused" 1 "shell tracing is enabled" -- bash -x "$helper" check-recipient
expect "BASH_XTRACEFD is refused" 1 "BASH_XTRACEFD is set" -- env BASH_XTRACEFD=2 bash "$helper" check-recipient
expect "committed recipient passes" ok "PASS" -- bash "$helper" check-recipient
expect "test recipient passes" ok "PASS" -- run_test_mode bash "$helper" check-recipient
printf '%s\r\n' "$fake_recipient" >"${tmp}/recipient-crlf.txt"
expect "CRLF recipient fails" 1 "FAIL" -- env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="${tmp}/recipient-crlf.txt" bash "$helper" check-recipient
printf '%s\n%s\n' "$fake_recipient" "$fake_recipient" >"${tmp}/recipient-two.txt"
expect "two-line recipient fails" 1 "FAIL" -- env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="${tmp}/recipient-two.txt" bash "$helper" check-recipient

if [[ "$(id -u)" -ne 0 ]]; then
  expect "production encrypt requires root" 1 "run this subcommand as root" -- \
    env PATH="$stub_path" bash "$helper" encrypt --item k3s-server-token --source "$source_file" --out "${tmp}/x.age"
  expect "production verify requires root" 1 "run this subcommand as root" -- \
    env PATH="$stub_path" bash "$helper" verify --item k3s-server-token --ciphertext "${tmp}/x.age" --source "$source_file"
else
  skipped=$((skipped + 2))
  echo "skip production root checks (running as root)"
fi

expect "unknown item is refused" 1 "unknown item" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item other --source "$source_file" --out "${tmp}/x.age"
expect "missing argument value is refused" 1 "missing value for argument" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item
expect "non-.age output is refused" 1 "output must end in .age" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${tmp}/x.txt"
: >"${tmp}/exists.age"
expect "existing output is refused" 1 "output already exists" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${tmp}/exists.age"
expect "wrong age version is refused" 1 "age v1.3.2 is required (found v1.3.1)" -- \
  run_test_mode env PATH="$stub_path" STUB_AGE_VERSION=v1.3.1 bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${tmp}/v.age"

no_age_path="${tmp}/no-age"
mkdir -p "$no_age_path"
for tool in bash env id cat wc grep awk stat cut sha256sum dirname mktemp rm chmod ls; do
  ln -sf "$(command -v "$tool")" "${no_age_path}/${tool}"
done
expect "missing age is refused" 1 "age is not installed" -- \
  run_test_mode env PATH="$no_age_path" bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${tmp}/n.age"

open_dir="$(fresh_dir)"
chmod 0770 "$open_dir"
expect "group-writable output directory is refused" 1 "writable by group or others" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${open_dir}/g.age"
ln -s "$(fresh_dir)" "${tmp}/dir-link"
expect "symlinked output directory is refused" 1 "is a symbolic link" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "$source_file" --out "${tmp}/dir-link/s.age"

ln -s "$source_file" "${tmp}/source-link"
expect "symlinked source is refused" 1 "source is a symbolic link" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "${tmp}/source-link" --out "${tmp}/l.age"
printf 'x\n' >"${tmp}/source-open"
chmod 0644 "${tmp}/source-open"
expect "group/other-readable source is refused" 1 "accessible to group or others" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "${tmp}/source-open" --out "${tmp}/o.age"
: >"${tmp}/source-empty"
chmod 0600 "${tmp}/source-empty"
expect "empty source is refused" 1 "source is empty" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "${tmp}/source-empty" --out "${tmp}/e.age"
expect "missing source is refused" 1 "source does not exist" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item grafana-admin --source "${tmp}/absent" --out "${tmp}/a.age"

write_header "${tmp}/one-x25519.age" X25519
write_header "${tmp}/two-x25519.age" X25519 X25519
write_header "${tmp}/scrypt.age" scrypt
printf 'not an age file\n' >"${tmp}/plain-identity.txt"
expect "passphrase variable is refused" 1 "AGE_PASSPHRASE is set" -- \
  run_test_mode env PATH="$stub_path" AGE_PASSPHRASE=x bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/one-x25519.age" --source "$source_file"
expect "custom passphrase variable is refused" 1 "MY_PASSPHRASE is set" -- \
  run_test_mode env PATH="$stub_path" MY_PASSPHRASE=x bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/one-x25519.age" --source "$source_file"
expect "two-recipient ciphertext is refused" 1 "ciphertext header check failed" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/two-x25519.age" --source "$source_file"
expect "non-age ciphertext is refused" 1 "ciphertext header check failed" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" verify --item grafana-admin \
  --ciphertext "$source_file" --source "$source_file"
expect "plaintext identity as archive is refused" 1 "not a passphrase-encrypted age file" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/one-x25519.age" --source "$source_file" --identity-archive "${tmp}/plain-identity.txt"
expect "test mode refuses the passphrase prompt" 1 "test mode cannot prompt" -- \
  run_test_mode env PATH="$stub_path" bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/one-x25519.age" --source "$source_file" --identity-archive "${tmp}/scrypt.age"

busy="$(fresh_dir)"
: >"${busy}/leftover"
expect "non-empty test tmpdir is refused" 1 "test directory must be empty" -- \
  run_test_mode env PATH="$stub_path" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
  RECOVERY_MATERIAL_TEST_TMPDIR="$busy" bash "$helper" verify --item grafana-admin \
  --ciphertext "${tmp}/one-x25519.age" --source "$source_file"

# TERM during decryption: the trap must remove the decrypted file and exit 143.
term_dir="$(fresh_dir)"
pidfile="${tmp}/stub-age.pid"
set +e
run_test_mode env PATH="$stub_path" STUB_AGE_SLEEP_PIDFILE="$pidfile" \
  RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" RECOVERY_MATERIAL_TEST_TMPDIR="$term_dir" \
  bash "$helper" verify --item grafana-admin --ciphertext "${tmp}/one-x25519.age" --source "$source_file" \
  >"${tmp}/term.out" 2>&1 &
helper_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$pidfile" ]] && break
  sleep 0.1
done
helper_bash="$(pgrep -P "$helper_pid" -f recovery-material.sh || echo "$helper_pid")"
kill -TERM "$helper_bash" 2>/dev/null
kill -TERM "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
wait "$helper_pid"
term_rc=$?
set -e
if [[ "$term_rc" -eq 143 ]] && empty_dir "$term_dir"; then
  pass "TERM during decryption cleans up and exits 143"
else
  fail "TERM during decryption cleans up and exits 143" "exit ${term_rc}; tmpdir contents: $(find "$term_dir" -mindepth 1 -maxdepth 1 -printf '%f ')"
fi

# --- group B: real round trips ------------------------------------------------------
echo "Group B: round trips (real age, throwaway identity)"
real_age_ok=0
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
  && [[ "$(age --version 2>/dev/null)" == "v1.3.2" ]]; then
  real_age_ok=1
fi

if (( real_age_ok )); then
  key_dir="$(fresh_dir)"
  age-keygen -o "${key_dir}/identity" 2>/dev/null
  age-keygen -y "${key_dir}/identity" >"${key_dir}/recipient"
  age-keygen -o "${key_dir}/other-identity" 2>/dev/null
  age-keygen -y "${key_dir}/other-identity" >"${key_dir}/other-recipient"
  round() {
    env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="${key_dir}/recipient" \
      RECOVERY_MATERIAL_TEST_IDENTITY="${key_dir}/identity" "$@"
  }

  out_dir="$(fresh_dir)"
  expect "encrypt succeeds" ok "ciphertext sha256: " -- \
    round bash "$helper" encrypt --item k3s-server-token --source "$source_file" --out "${out_dir}/token.age"
  if [[ -f "${out_dir}/token.age" ]]; then
    recorded="$(sed -n 's/^ciphertext sha256: //p' "${tmp}/out")"
    if [[ "$recorded" == "$(sha256sum "${out_dir}/token.age" | cut -d' ' -f1)" \
      && "$(stat -c '%a' "${out_dir}/token.age")" == "600" \
      && "$(head -n 1 "${out_dir}/token.age")" == "age-encryption.org/v1" \
      && "$(grep -ac '^-> X25519 ' "${out_dir}/token.age")" == "1" ]] \
      && ! grep -aqF "$sentinel" "${out_dir}/token.age"; then
      pass "ciphertext has the printed SHA-256, mode 600, one X25519 stanza, no plaintext"
    else
      fail "ciphertext properties" "hash, mode, header or plaintext check failed"
    fi
  else
    fail "ciphertext properties" "no ciphertext written"
  fi

  verify_dir="$(fresh_dir)"
  expect "verify reports MATCH" ok "result: MATCH" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$verify_dir" bash "$helper" verify --item k3s-server-token \
    --ciphertext "${out_dir}/token.age" --source "$source_file"
  if empty_dir "$verify_dir"; then pass "verify leaves no plaintext behind"; else fail "verify cleanup" "tmpdir not empty"; fi

  printf '%s-changed\n' "$sentinel" >"${tmp}/source-changed"
  chmod 0600 "${tmp}/source-changed"
  differ_dir="$(fresh_dir)"
  expect "verify reports DIFFER for a changed source" 1 "result: DIFFER" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$differ_dir" bash "$helper" verify --item k3s-server-token \
    --ciphertext "${out_dir}/token.age" --source "${tmp}/source-changed"
  if empty_dir "$differ_dir"; then pass "DIFFER leaves no plaintext behind"; else fail "DIFFER cleanup" "tmpdir not empty"; fi

  age -R "${key_dir}/other-recipient" -o "${out_dir}/other.age" -- "$source_file"
  wrong_dir="$(fresh_dir)"
  expect "verify fails for another recipient's ciphertext" 1 "age decryption failed" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$wrong_dir" bash "$helper" verify --item k3s-server-token \
    --ciphertext "${out_dir}/other.age" --source "$source_file"
  if empty_dir "$wrong_dir"; then pass "failed decryption leaves no plaintext behind"; else fail "failed decryption cleanup" "tmpdir not empty"; fi

  age -R "${key_dir}/recipient" -R "${key_dir}/other-recipient" -o "${out_dir}/both.age" -- "$source_file"
  expect "verify refuses a two-recipient ciphertext" 1 "ciphertext header check failed" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" bash "$helper" verify --item k3s-server-token \
    --ciphertext "${out_dir}/both.age" --source "$source_file"
elif [[ "${RECOVERY_MATERIAL_REQUIRE_AGE:-}" == "1" ]]; then
  fail "group B" "age and age-keygen v1.3.2 are required (RECOVERY_MATERIAL_REQUIRE_AGE=1)"
else
  skipped=$((skipped + 1))
  echo "skip group B: age and age-keygen v1.3.2 are not on PATH"
fi

# --- group C: S3 helper against a stub aws --------------------------------------------
echo "Group C: S3 helper (stub aws)"
stub_aws_dir="${tmp}/stub-aws"
store="${tmp}/store"
mkdir -p "$stub_aws_dir" "$store"
cat >"${stub_aws_dir}/aws" <<'EOF'
#!/usr/bin/env bash
# Minimal stand-in for the AWS CLI calls made by recovery-material-s3.sh.
set -euo pipefail
args=()
while (( $# )); do
  case "$1" in
    --profile | --region) shift 2 ;;
    --no-cli-pager | --no-cli-auto-prompt) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
service="${args[0]}" operation="${args[1]}"
key="" body="" version="" checksum="" bucket="" outfile="" query=""
# Every remaining option takes a value; the first bare word is the positional
# outfile (get-object), wherever it appears.
for ((i = 2; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --bucket) bucket="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --key) key="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --body) body="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --version-id) version="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --checksum-sha256) checksum="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --query) query="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --*) i=$((i + 1)) ;;
    *) [[ -z "$outfile" ]] && outfile="${args[$i]}" ;;
  esac
done
error() {
  echo "An error occurred ($1) when calling the $2 operation: User: ${FAKE_AWS_ARN} is not authorized on ${bucket}" >&2
  exit 254
}
b64sha() { python3 -c 'import base64,hashlib,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$1"; }
[[ -z "${FAKE_AWS_FAIL:-}" || "$service $operation" == "sts get-caller-identity" ]] || error "$FAKE_AWS_FAIL" "$operation"
# The current version is the object file. Once a key has a second version, every
# version is also kept as <object>.stub-version-N.
object="${FAKE_AWS_STORE}/$(printf '%s' "$key" | tr '/' '_')"
case "$service $operation" in
  "sts get-caller-identity") echo "$FAKE_AWS_ARN" ;;
  "s3api head-object")
    [[ -f "$object" ]] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
    if [[ "$query" == "ChecksumSHA256" ]]; then
      if [[ -n "${FAKE_AWS_NO_CHECKSUM:-}" ]]; then echo "None"; else b64sha "$object"; fi
    else
      echo '{}'
    fi ;;
  "s3api put-object")
    actual="$(b64sha "$body")"
    [[ "$actual" == "$checksum" ]] || error BadDigest PutObject
    n=1
    if [[ -f "$object" ]]; then
      [[ -f "${object}.stub-version-1" ]] || cp -- "$object" "${object}.stub-version-1"
      n=$(( $(find "$FAKE_AWS_STORE" -maxdepth 1 -name "${object##*/}.stub-version-*" | wc -l) + 1 ))
    fi
    cp -- "$body" "$object"
    (( n == 1 )) || cp -- "$body" "${object}.stub-version-${n}"
    # Plants a path during the upload, after the helper's own pre-checks.
    if [[ -n "${FAKE_AWS_PLANT:-}" ]]; then
      case "${FAKE_AWS_PLANT_KIND:-file}" in
        file) printf 'planted\n' >"$FAKE_AWS_PLANT" ;;
        fifo) mkfifo -m 0600 "$FAKE_AWS_PLANT" ;;
        devnull) ln -s /dev/null "$FAKE_AWS_PLANT" ;;
        dangling) ln -s "${FAKE_AWS_PLANT}.absent" "$FAKE_AWS_PLANT" ;;
        filelink) printf 'target\n' >"${FAKE_AWS_PLANT}.target"; ln -s "${FAKE_AWS_PLANT}.target" "$FAKE_AWS_PLANT" ;;
      esac
    fi
    printf '%s\n' "${FAKE_AWS_VERSION:-stub-version-${n}}" ;;
  "s3api get-object")
    src=""
    if [[ "$version" == "stub-version-1" && ! -f "${object}.stub-version-1" && -f "$object" ]]; then
      src="$object"
    elif [[ "$version" =~ ^stub-version-[0-9]+$ && -f "${object}.${version}" ]]; then
      src="${object}.${version}"
    fi
    [[ -n "$src" ]] || error NoSuchVersion GetObject
    [[ -n "$outfile" ]] || { echo "stub aws: no outfile" >&2; exit 2; }
    cp -- "$src" "$outfile"
    echo "${FAKE_AWS_RETURNED_VERSION:-$version}" ;;
  *) echo "stub aws: unsupported call" >&2; exit 2 ;;
esac
EOF
chmod 0755 "${stub_aws_dir}/aws"

routine_arn="arn:aws:sts::${fake_account}:assumed-role/AWSReservedSSO_HomeClusterBackupOperator_0123456789abcdef/operator"
admin_arn="arn:aws:sts::${fake_account}:assumed-role/AWSReservedSSO_AdministratorAccess_0123456789abcdef/operator"
s3() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE \
    PATH="${stub_aws_dir}:${PATH}" FAKE_AWS_STORE="$store" FAKE_AWS_ARN="${FAKE_ARN:-$routine_arn}" \
    HOME_CLUSTER_BACKUP_BUCKET="$fake_bucket" "$@"
}

write_header "${tmp}/upload.age" X25519
expect "routine role passes check-role" ok "PASS" -- s3 bash "$s3_helper" check-role
FAKE_ARN="$admin_arn" expect "administrator role fails check-role" 1 "FAIL" -- s3 bash "$s3_helper" check-role
expect "upload succeeds" ok "version id: stub-version-1" -- \
  s3 bash "$s3_helper" upload --item k3s-server-token --date 2026-10-20 --file "${tmp}/upload.age"
expect "upload to an existing key is refused" 1 "already exists" -- \
  s3 bash "$s3_helper" upload --item k3s-server-token --date 2026-10-20 --file "${tmp}/upload.age"
expect "AccessDenied is reported by code only" 1 "failed: AccessDenied" -- \
  s3 env FAKE_AWS_FAIL=AccessDenied bash "$s3_helper" upload --item grafana-admin --date 2026-10-20 --file "${tmp}/upload.age"
expect "non-age upload is refused" 1 "not a single-recipient X25519 age ciphertext" -- \
  s3 bash "$s3_helper" upload --item grafana-admin --date 2026-10-20 --file "$source_file"
expect "bad date is refused" 1 "--date must be YYYY-MM-DD" -- \
  s3 bash "$s3_helper" upload --item grafana-admin --date 20261020 --file "${tmp}/upload.age"
expect "static access keys are refused" 1 "AWS_ACCESS_KEY_ID is set" -- \
  env AWS_ACCESS_KEY_ID=x bash "$s3_helper" check-role
expect "bad bucket name is refused" 1 "does not match the expected pattern" -- \
  s3 env HOME_CLUSTER_BACKUP_BUCKET=other-bucket bash "$s3_helper" upload --item grafana-admin --date 2026-10-20 --file "${tmp}/upload.age"
expect "download reports MATCH" ok "result: MATCH" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id stub-version-1 \
  --out "${tmp}/downloaded.age" --compare-with "${tmp}/upload.age"
write_header "${tmp}/tampered.age" X25519
printf 'extra' >>"${tmp}/tampered.age"
cp -- "${tmp}/tampered.age" "${store}/recovery_k3s-server-token_2026-10-20.age"
expect "download reports DIFFER for a changed object" 1 "result: DIFFER" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id stub-version-1 \
  --out "${tmp}/downloaded-2.age" --compare-with "${tmp}/upload.age"
expect "unknown version is reported by code only" 1 "get-object failed: NoSuchVersion" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id other \
  --out "${tmp}/downloaded-3.age" --compare-with "${tmp}/upload.age"
if [[ ! -e "${tmp}/downloaded-3.age" ]]; then pass "failed download leaves no output file"; else fail "failed download" "output file left behind"; fi
expect "mismatched returned version is refused" 1 "different version than requested" -- \
  s3 env FAKE_AWS_RETURNED_VERSION=stub-version-2 bash "$s3_helper" download --item k3s-server-token \
  --date 2026-10-20 --version-id stub-version-1 --out "${tmp}/downloaded-4.age" --compare-with "${tmp}/upload.age"
if [[ ! -e "${tmp}/downloaded-4.age" ]]; then pass "rejected download is not copied to --out"; else fail "rejected download" "output file left behind"; fi
printf 'pre-existing content\n' >"${tmp}/downloaded-5.age"
before_hash="$(sha256sum "${tmp}/downloaded-5.age" | cut -d' ' -f1)"
expect "existing download output is refused" 1 "output already exists" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id stub-version-1 \
  --out "${tmp}/downloaded-5.age" --compare-with "${tmp}/upload.age"
if [[ -f "${tmp}/downloaded-5.age" && "$(sha256sum "${tmp}/downloaded-5.age" | cut -d' ' -f1)" == "$before_hash" ]]; then
  pass "refused existing output is left unchanged"
else
  fail "refused existing output" "the pre-existing file was changed or removed"
fi
printf 'link target\n' >"${tmp}/link-target"
target_hash="$(sha256sum "${tmp}/link-target" | cut -d' ' -f1)"
ln -s "${tmp}/link-target" "${tmp}/downloaded-link.age"
expect "symlinked download output is refused" 1 "output already exists" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id stub-version-1 \
  --out "${tmp}/downloaded-link.age" --compare-with "${tmp}/upload.age"
if [[ -L "${tmp}/downloaded-link.age" && "$(sha256sum "${tmp}/link-target" | cut -d' ' -f1)" == "$target_hash" ]]; then
  pass "refused symlink and its target are left unchanged"
else
  fail "refused symlink" "the link or its target was changed"
fi

# A final copy that fails part-way (as on a full filesystem) must leave no --out file.
# A stub cat on PATH writes a few bytes and then fails.
fail_cat_dir="${tmp}/stub-cat"
mkdir -p "$fail_cat_dir"
cat >"${fail_cat_dir}/cat" <<'EOF'
#!/usr/bin/env bash
head -c 5 -- "${@: -1}"
exit 1
EOF
chmod 0755 "${fail_cat_dir}/cat"
expect "failed final copy is reported" 1 "the partial output was removed" -- \
  s3 env PATH="${fail_cat_dir}:${stub_aws_dir}:${PATH}" bash "$s3_helper" download --item k3s-server-token \
  --date 2026-10-20 --version-id stub-version-1 --out "${tmp}/downloaded-partial.age" --compare-with "${tmp}/upload.age"
if [[ ! -e "${tmp}/downloaded-partial.age" && ! -L "${tmp}/downloaded-partial.age" ]]; then
  pass "failed final copy leaves no --out file"
else
  fail "failed final copy" "a partial output file was left behind"
fi

# The normal path still works after the failure cases.
cp -- "${tmp}/upload.age" "${store}/recovery_k3s-server-token_2026-10-20.age"
expect "download after the failure cases reports MATCH" ok "result: MATCH" -- \
  s3 bash "$s3_helper" download --item k3s-server-token --date 2026-10-20 --version-id stub-version-1 \
  --out "${tmp}/downloaded-final.age" --compare-with "${tmp}/upload.age"
if cmp -s "${tmp}/downloaded-final.age" "${tmp}/upload.age" && [[ "$(stat -c '%a' "${tmp}/downloaded-final.age")" == "600" ]]; then
  pass "successful download is complete and mode 600"
else
  fail "successful download" "content or mode differs"
fi
expect "unexpected version output is refused" 1 "no usable version ID" -- \
  s3 env FAKE_AWS_VERSION=None bash "$s3_helper" upload --item grafana-admin --date 2026-10-21 --file "${tmp}/upload.age"
expect "multi-line version output is refused" 1 "no usable version ID" -- \
  s3 env FAKE_AWS_VERSION=$'stub-version-1\nextra' bash "$s3_helper" upload --item grafana-admin --date 2026-10-22 --file "${tmp}/upload.age"
expect "profile override is refused" 1 "AWS_DEFAULT_PROFILE is set" -- \
  env AWS_DEFAULT_PROFILE=other bash "$s3_helper" check-role

# The base64 SHA-256 must survive digests containing zero bytes. Find a ciphertext
# whose digest has a 00 byte, then let the stub compare against Python's encoding.
zero_file="${tmp}/zero-digest.age"
found=0
for n in $(seq 1 2000); do
  write_header "$zero_file" X25519
  printf '%s' "$n" >>"$zero_file"
  if sha256sum "$zero_file" | cut -d' ' -f1 | grep -Eq '^(..)*00'; then
    found=1
    break
  fi
done
if (( found )); then
  expect "checksum with a zero byte matches S3's expectation" ok "version id: stub-version-1" -- \
    s3 bash "$s3_helper" upload --item recovery-inventory --date 2026-10-23 --file "$zero_file"
else
  fail "zero-byte checksum" "no fixture with a zero digest byte was found"
fi

# --- group D: encryption-config ------------------------------------------------------
echo "Group D: encryption-config (synthetic K3s secrets-encryption configuration)"
item=encryption-config
# A synthetic configuration in the K3s v1.36 shape, with a random key generated here.
enc_key="$(head -c 32 /dev/urandom | base64 -w 0)"
enc_name="secretbox-test-${RANDOM}${RANDOM}"
enc_source="${tmp}/encryption-config.json"
printf '{"kind":"EncryptionConfiguration","apiVersion":"apiserver.config.k8s.io/v1","resources":[{"resources":["secrets"],"providers":[{"secretbox":{"keys":[{"name":"%s","secret":"%s"}]}},{"identity":{}}]}]}\n' \
  "$enc_name" "$enc_key" >"$enc_source"
chmod 0600 "$enc_source"
enc_plain_sha="$(sha256sum "$enc_source" | cut -d' ' -f1)"
never_print+=("$enc_key" "$enc_name" "$enc_plain_sha" "$sentinel")

me="$(id -u):$(id -g)"
other_user="$(( $(id -u) + 1 )):$(id -g)"
other_group="$(id -u):$(( $(id -g) + 1 ))"
root_check="source check: PASS (regular file, nonempty, mode 600, no group or other access, owner root:root, expected path, directory root:root and not group or other writable)"

# The synthetic configuration stands in for the production path through the
# test-only expected-source override. Exported for the direct calls below; enc_*
# and ec_verify bind each call to the file it tests, unless expected_source is set.
export RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$enc_source"
# source_owner and parent_owner, when set, replace the required root:root owner
# (uid:gid) of the file and of its directory in test mode; empty means the test
# user's own, standing in for root:root.
source_owner=""
parent_owner=""
expected_source=""
source_arg() {
  while (( $# )); do
    [[ "$1" == "--source" ]] && { printf '%s' "$2"; return; }
    shift
  done
}
enc_env() {
  local bound="${expected_source:-$(source_arg "$@")}"
  printf '%s\0' RECOVERY_MATERIAL_TEST_SOURCE_OWNER="$source_owner" RECOVERY_MATERIAL_TEST_PARENT_OWNER="$parent_owner" \
    RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$bound"
}
enc_encrypt() {
  local -a vars
  mapfile -d '' vars < <(enc_env "$@")
  run_test_mode env PATH="$stub_path" "${vars[@]}" bash "$helper" encrypt --item "$item" "$@"
}
enc_verify() {
  local -a vars
  mapfile -d '' vars < <(enc_env "$@")
  run_test_mode env PATH="$stub_path" "${vars[@]}" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
    RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" bash "$helper" verify --item "$item" "$@"
}

# Source checks, on both encrypt (stub age, so nothing is encrypted) and verify.
expect "encryption-config: missing source is refused" 1 "source does not exist" -- \
  enc_encrypt --source "${tmp}/absent.json" --out "${tmp}/ec-a.age"
ln -s "$enc_source" "${tmp}/ec-link.json"
expect "encryption-config: symlinked source is refused" 1 "source is a symbolic link" -- \
  enc_encrypt --source "${tmp}/ec-link.json" --out "${tmp}/ec-l.age"
ln -s "${tmp}/absent.json" "${tmp}/ec-dangling.json"
expect "encryption-config: dangling symlink source is refused" 1 "source is a symbolic link" -- \
  enc_encrypt --source "${tmp}/ec-dangling.json" --out "${tmp}/ec-dl.age"
ec_dir="$(fresh_dir)"
expect "encryption-config: directory source is refused" 1 "source is not a regular file" -- \
  enc_encrypt --source "$ec_dir" --out "${tmp}/ec-d.age"
mkfifo -m 0600 "${tmp}/ec-fifo"
expect "encryption-config: FIFO source is refused" 1 "source is not a regular file" -- \
  enc_encrypt --source "${tmp}/ec-fifo" --out "${tmp}/ec-f.age"
# /dev is root-owned; the parent override admits it so the file-type check is reached.
parent_owner=0:0
expect "encryption-config: device source is refused" 1 "source is not a regular file" -- \
  enc_encrypt --source /dev/null --out "${tmp}/ec-n.age"
parent_owner=""
: >"${tmp}/ec-empty.json"
chmod 0600 "${tmp}/ec-empty.json"
expect "encryption-config: empty source is refused" 1 "source is empty" -- \
  enc_encrypt --source "${tmp}/ec-empty.json" --out "${tmp}/ec-e.age"
# The source is owned by the test user; requiring another owner simulates a source
# that is not owned by root:root (wrong user, or wrong group).
for source_owner in 0:0 "$other_user" "$other_group"; do
  expect "encryption-config: encrypt refuses a source not owned by the required ${source_owner}" 1 "source is not owned by root:root (owner ${me})" -- \
    enc_encrypt --source "$enc_source" --out "${tmp}/ec-o.age"
  expect "encryption-config: verify refuses a source not owned by the required ${source_owner}" 1 "source is not owned by root:root (owner ${me})" -- \
    enc_verify --ciphertext "${tmp}/one-x25519.age" --source "$enc_source"
done
source_owner=""
if [[ ! -e "${tmp}/ec-o.age" ]]; then pass "encryption-config: refused sources leave no ciphertext"; else fail "refused source" "ciphertext written"; fi
# Ownership applies only to encryption-config: the existing items keep their checks.
for other_item in k3s-server-token grafana-admin recovery-inventory; do
  expect "${other_item}: still accepted without root:root ownership (reaches age)" 1 "age encryption or the exclusive write failed" -- \
    run_test_mode env PATH="$stub_path" RECOVERY_MATERIAL_TEST_SOURCE_OWNER=0:0 bash "$helper" encrypt --item "$other_item" \
    --source "$source_file" --out "${tmp}/regress-${other_item}.age"
done
expect "encryption-config: a correctly owned source reaches age (stub refuses real work)" 1 "age encryption or the exclusive write failed" -- \
  enc_encrypt --source "$enc_source" --out "${tmp}/ec-ok-stub.age"
if [[ ! -e "${tmp}/ec-ok-stub.age" ]]; then pass "encryption-config: failed encryption removes its partial output"; else fail "failed encryption" "partial output left"; fi
for mode in 0640 0604 0620 0602 0610 0601 0660 0644 0666; do
  cp -- "$enc_source" "${tmp}/ec-mode-${mode}.json"
  chmod "$mode" "${tmp}/ec-mode-${mode}.json"
  expect "encryption-config: mode ${mode} source is refused" 1 "accessible to group or others (mode ${mode#0})" -- \
    enc_encrypt --source "${tmp}/ec-mode-${mode}.json" --out "${tmp}/ec-m${mode}.age"
done
for version in v1.3.1 v1.4.0 v1.3.2-rc.1; do
  expect "encryption-config: age ${version} is refused" 1 "age v1.3.2 is required (found ${version})" -- \
    run_test_mode env PATH="$stub_path" STUB_AGE_VERSION="$version" bash "$helper" encrypt --item "$item" \
    --source "$enc_source" --out "${tmp}/ec-v.age"
done
expect "encryption-config: missing age is refused" 1 "age is not installed" -- \
  run_test_mode env PATH="$no_age_path" bash "$helper" encrypt --item "$item" --source "$enc_source" --out "${tmp}/ec-na.age"
expect "encryption-config: wrong age version is refused by verify" 1 "age v1.3.2 is required (found v1.3.1)" -- \
  run_test_mode env PATH="$stub_path" STUB_AGE_VERSION=v1.3.1 RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
  RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" bash "$helper" verify --item "$item" \
  --ciphertext "${tmp}/one-x25519.age" --source "$enc_source"
expect "encryption-config: mode 0640 source is refused by verify" 1 "accessible to group or others (mode 640)" -- \
  enc_verify --ciphertext "${tmp}/one-x25519.age" --source "${tmp}/ec-mode-0640.json"
expect "encryption-config: symlinked source is refused by verify" 1 "source is a symbolic link" -- \
  enc_verify --ciphertext "${tmp}/one-x25519.age" --source "${tmp}/ec-link.json"

# Source-path binding. bind_root stands in for /var/lib/rancher/k3s/server, and
# bound for its cred/encryption-config.json.
prod_source="/var/lib/rancher/k3s/server/cred/encryption-config.json"
if grep -qxF "ENCRYPTION_CONFIG_SOURCE=\"${prod_source}\"" "$helper"; then
  pass "encryption-config: the production source is bound to ${prod_source}"
else
  fail "encryption-config: production source" "the committed production path differs"
fi
bind_root="$(fresh_dir)"
cred="${bind_root}/cred"
mkdir -m 0700 "$cred"
bound="${cred}/encryption-config.json"
cp -- "$enc_source" "$bound"
chmod 0600 "$bound"
cp -- "$enc_source" "${cred}/other-config.json"
chmod 0600 "${cred}/other-config.json"
reaches_age="age encryption or the exclusive write failed"

expected_source="$bound"
expect "encryption-config: the exact expected path is accepted (reaches age)" 1 "$reaches_age" -- \
  enc_encrypt --source "$bound" --out "${tmp}/b-ok.age"
expect "encryption-config: an alternate root-owned file is refused" 1 "source must be exactly ${bound}" -- \
  enc_encrypt --source "${cred}/other-config.json" --out "${tmp}/b-alt.age"
expect "encryption-config: verify also refuses an alternate file" 1 "source must be exactly ${bound}" -- \
  enc_verify --ciphertext "${tmp}/one-x25519.age" --source "${cred}/other-config.json"
rel_encrypt() { (cd "$cred" && enc_encrypt --source encryption-config.json --out "${tmp}/b-rel.age"); }
expect "encryption-config: a relative path is refused" 1 "source must be exactly ${bound}" -- rel_encrypt
for alias in "${cred}/./encryption-config.json" "${cred}//encryption-config.json" \
  "${bind_root}/cred/../cred/encryption-config.json" "${bind_root}//cred/encryption-config.json" "${bound}/"; do
  expect "encryption-config: the alias ${alias#"$bind_root"} is refused" 1 "source must be exactly ${bound}" -- \
    enc_encrypt --source "$alias" --out "${tmp}/b-alias.age"
done
ln -s "$cred" "${bind_root}/cred-link"
expect "encryption-config: the real path given through a symlinked directory is refused" 1 "source must be exactly ${bound}" -- \
  enc_encrypt --source "${bind_root}/cred-link/encryption-config.json" --out "${tmp}/b-l0.age"
expected_source=""

# Final-component symlink, and symlinked parents, even when the expected path names them.
ln -s "$bound" "${cred}/link-config.json"
expect "encryption-config: a final-component symlink is refused" 1 "source is a symbolic link" -- \
  enc_encrypt --source "${cred}/link-config.json" --out "${tmp}/b-l1.age"
expect "encryption-config: a symlinked parent directory is refused" 1 "a directory in the source path is a symbolic link: ${bind_root}/cred-link" -- \
  enc_encrypt --source "${bind_root}/cred-link/encryption-config.json" --out "${tmp}/b-l2.age"
ln -s "$bind_root" "${tmp}/root-link"
expect "encryption-config: a symlinked ancestor directory is refused" 1 "a directory in the source path is a symbolic link: ${tmp}/root-link" -- \
  enc_encrypt --source "${tmp}/root-link/cred/encryption-config.json" --out "${tmp}/b-l3.age"

# The canonical-path check backs up the checks above, which already refuse every
# alias a test can build; a stub realpath that disagrees, or fails, shows that it is
# applied and fails closed.
stub_realpath_dir="${tmp}/stub-realpath"
mkdir -p "$stub_realpath_dir"
cat >"${stub_realpath_dir}/realpath" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_REALPATH_FAIL:-}" ]] && exit 1
echo "/elsewhere/encryption-config.json"
EOF
chmod 0755 "${stub_realpath_dir}/realpath"
expect "encryption-config: a canonical path that differs is refused" 1 "does not resolve to the expected path" -- \
  run_test_mode env PATH="${stub_realpath_dir}:${stub_path}" RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$bound" bash "$helper" \
  encrypt --item "$item" --source "$bound" --out "${tmp}/b-rp.age"
expect "encryption-config: an unresolvable canonical path is refused" 1 "could not be resolved" -- \
  run_test_mode env PATH="${stub_realpath_dir}:${stub_path}" STUB_REALPATH_FAIL=1 RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$bound" \
  bash "$helper" encrypt --item "$item" --source "$bound" --out "${tmp}/b-rp2.age"

# The credential directory.
expect "encryption-config: a missing credential directory is refused" 1 "credential directory does not exist: ${bind_root}/absent" -- \
  enc_encrypt --source "${bind_root}/absent/encryption-config.json" --out "${tmp}/b-m.age"
printf 'x\n' >"${bind_root}/plain-file"
expect "encryption-config: a credential directory that is not a directory is refused" 1 "credential directory is not a directory: ${bind_root}/plain-file" -- \
  enc_encrypt --source "${bind_root}/plain-file/encryption-config.json" --out "${tmp}/b-nd.age"
for parent_owner in 0:0 "$other_user" "$other_group"; do
  expect "encryption-config: a credential directory not owned by the required ${parent_owner} is refused" 1 \
    "credential directory is not owned by root:root (owner ${me}): ${cred}" -- \
    enc_encrypt --source "$bound" --out "${tmp}/b-po.age"
done
parent_owner=""
for mode in 0720 0702 0770 0777 1777; do
  wdir="${bind_root}/cred-${mode}"
  mkdir "$wdir"
  chmod "$mode" "$wdir"
  cp -- "$bound" "${wdir}/encryption-config.json"
  expect "encryption-config: a mode ${mode} credential directory is refused" 1 "credential directory is writable by group or others (mode ${mode#0})" -- \
    enc_encrypt --source "${wdir}/encryption-config.json" --out "${tmp}/b-w.age"
done
for mode in 0750 0755 0711; do
  rdir="${bind_root}/cred-r${mode}"
  mkdir "$rdir"
  chmod "$mode" "$rdir"
  cp -- "$bound" "${rdir}/encryption-config.json"
  expect "encryption-config: a mode ${mode} credential directory (not writable) is accepted (reaches age)" 1 "$reaches_age" -- \
    enc_encrypt --source "${rdir}/encryption-config.json" --out "${tmp}/b-r.age"
done

# The test-only override.
expect "encryption-config: without the override, test mode binds to the production path" 1 "source must be exactly ${prod_source}" -- \
  run_test_mode env -u RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE PATH="$stub_path" bash "$helper" encrypt --item "$item" \
  --source "$bound" --out "${tmp}/b-np.age"
for bad_override in "relative/encryption-config.json" "${cred}/./encryption-config.json" "${bind_root}/x/../cred/encryption-config.json" "${cred}/"; do
  expect "encryption-config: a non-normalized override (${bad_override#"$bind_root"}) is refused" 1 "must be an absolute, normalized path" -- \
    run_test_mode env PATH="$stub_path" RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$bad_override" bash "$helper" encrypt \
    --item "$item" --source "$bad_override" --out "${tmp}/b-bo.age"
done
for name in RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE RECOVERY_MATERIAL_TEST_SOURCE_OWNER RECOVERY_MATERIAL_TEST_PARENT_OWNER; do
  for subcommand in encrypt verify check-recipient; do
    expect "encryption-config: ${name} outside test mode is refused (${subcommand})" 1 "${name} is test-only and is refused outside test mode" -- \
      env -u RECOVERY_MATERIAL_TEST -u RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE PATH="$stub_path" "${name}=${bound}" bash "$helper" \
      "$subcommand" --item "$item" --source "$bound" --out "${tmp}/b-prod.age" --ciphertext "${tmp}/one-x25519.age"
  done
done
expect "encryption-config: an empty test-only variable outside test mode is refused" 1 "is test-only and is refused outside test mode" -- \
  env -u RECOVERY_MATERIAL_TEST RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE= PATH="$stub_path" bash "$helper" check-recipient
stub_id_dir="${tmp}/stub-id"
mkdir -p "$stub_id_dir"
# A stub id that reports uid 0, standing in for root.
cat >"${stub_id_dir}/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod 0755 "${stub_id_dir}/id"
expect "encryption-config: the override with test mode is refused for root" 1 "test mode must not run as root" -- \
  run_test_mode env PATH="${stub_id_dir}:${stub_path}" RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$bound" bash "$helper" encrypt \
  --item "$item" --source "$bound" --out "${tmp}/b-root.age"
if [[ ! -e "${tmp}/b-prod.age" && ! -e "${tmp}/b-root.age" && ! -e "${tmp}/b-alt.age" ]]; then
  pass "encryption-config: refused bindings write no ciphertext"
else
  fail "encryption-config: refused bindings" "a ciphertext was written"
fi
# The binding applies to encryption-config only: the other items accept any protected path.
for other_item in k3s-server-token grafana-admin recovery-inventory; do
  expect "${other_item}: not bound to the encryption-config path (reaches age)" 1 "$reaches_age" -- \
    run_test_mode env PATH="$stub_path" bash "$helper" encrypt --item "$other_item" --source "${cred}/other-config.json" \
    --out "${tmp}/b-${other_item}.age"
done

# Invalid ciphertext headers.
{ printf 'age-encryption.org/v1\n-> X25519 c3RhbnphYXJn\nYm9keQ\n'; printf 'no mac line\n'; } >"${tmp}/no-mac.age"
{ printf 'age-encryption.org/v2\n-> X25519 c3RhbnphYXJn\nYm9keQ\n--- bWFj\n'; } >"${tmp}/bad-version.age"
printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n-----END AGE ENCRYPTED FILE-----\n' >"${tmp}/armored.age"
: >"${tmp}/empty.age"
for bad in two-x25519 scrypt no-mac bad-version armored empty; do
  expect "encryption-config: ${bad} ciphertext header is refused by verify" 1 "ciphertext header check failed" -- \
    enc_verify --ciphertext "${tmp}/${bad}.age" --source "$enc_source"
done
expect "encryption-config: the plaintext source as ciphertext is refused" 1 "ciphertext header check failed" -- \
  enc_verify --ciphertext "$enc_source" --source "$enc_source"

# Command failure: the stub age fails to decrypt; the result is ERROR and nothing is left.
fail_dir="$(fresh_dir)"
expect "encryption-config: failed decryption reports ERROR" 1 "result: ERROR" -- \
  run_test_mode env PATH="$stub_path" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
  RECOVERY_MATERIAL_TEST_TMPDIR="$fail_dir" bash "$helper" verify --item "$item" \
  --ciphertext "${tmp}/one-x25519.age" --source "$enc_source"
if empty_dir "$fail_dir"; then pass "encryption-config: cleanup after command failure"; else fail "command-failure cleanup" "tmpdir not empty"; fi

# Interruption during decryption: TERM, HUP and INT. The helper is started through a
# small Python exec wrapper that restores the default SIGINT disposition, because a
# background job of a non-interactive shell starts with SIGINT ignored, and bash
# cannot trap a signal ignored on entry.
interrupt_case() {
  local signal="$1" want="$2" dir pidfile rc helper_pid helper_bash
  dir="$(fresh_dir)"
  pidfile="${tmp}/stub-age-${signal}.pid"
  set +e
  run_test_mode env PATH="$stub_path" STUB_AGE_SLEEP_PIDFILE="$pidfile" \
    RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" RECOVERY_MATERIAL_TEST_TMPDIR="$dir" \
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$helper" verify --item "$item" --ciphertext "${tmp}/one-x25519.age" --source "$enc_source" \
    >"${tmp}/interrupt.out" 2>&1 &
  helper_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "$pidfile" ]] && break
    sleep 0.1
  done
  if [[ -z "$(ls -A -- "$dir")" ]]; then
    fail "encryption-config: ${signal} during decryption" "no decrypted stand-in was written before the signal"
  fi
  helper_bash="$(pgrep -P "$helper_pid" -f recovery-material.sh || echo "$helper_pid")"
  kill "-${signal}" "$helper_bash" 2>/dev/null
  kill "-${signal}" "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
  wait "$helper_pid"
  rc=$?
  set -e
  if [[ "$rc" -eq "$want" ]] && empty_dir "$dir" && ! leaked "${tmp}/interrupt.out"; then
    pass "encryption-config: ${signal} during decryption cleans up and exits ${want}"
  else
    fail "encryption-config: ${signal} during decryption cleans up and exits ${want}" \
      "exit ${rc}; tmpdir contents: $(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f ')"
  fi
}
interrupt_case TERM 143
interrupt_case HUP 129
interrupt_case INT 130

# Round trips with real age and a throwaway identity, as in group B.
if (( real_age_ok )); then
  ec_out="$(fresh_dir)"
  expect "encryption-config: accepted synthetic root-only source encrypts" ok "$root_check" -- \
    round bash "$helper" encrypt --item "$item" --source "$enc_source" --out "${ec_out}/encryption-config.age"
  if [[ -f "${ec_out}/encryption-config.age" ]]; then
    recorded="$(sed -n 's/^ciphertext sha256: //p' "${tmp}/out")"
    recorded_bytes="$(sed -n 's/^ciphertext bytes: //p' "${tmp}/out")"
    if [[ "$recorded" == "$(sha256sum "${ec_out}/encryption-config.age" | cut -d' ' -f1)" \
      && "$recorded_bytes" == "$(wc -c <"${ec_out}/encryption-config.age")" \
      && "$(stat -c '%a' "${ec_out}/encryption-config.age")" == "600" \
      && "$(head -n 1 "${ec_out}/encryption-config.age")" == "age-encryption.org/v1" \
      && "$(grep -ac '^-> X25519 ' "${ec_out}/encryption-config.age")" == "1" ]] \
      && ! grep -aqF -e "$enc_key" -e "$enc_name" "${ec_out}/encryption-config.age"; then
      pass "encryption-config: ciphertext has the printed SHA-256 and size, mode 600, one X25519 stanza, no key material"
    else
      fail "encryption-config: ciphertext properties" "hash, size, mode, header or key-material check failed"
    fi
  else
    fail "encryption-config: ciphertext properties" "no ciphertext written"
  fi
  chmod 0400 "${tmp}/ec-mode-0640.json"
  expect "encryption-config: mode 0400 source is accepted" ok "mode 400, no group or other access, owner root:root" -- \
    round env RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="${tmp}/ec-mode-0640.json" bash "$helper" encrypt --item "$item" --source "${tmp}/ec-mode-0640.json" --out "${ec_out}/ec-0400.age"

  # ec_verify DIR [NAME=VALUE...] -- VERIFY-ARGS...
  ec_verify() {
    local dir="$1" vars=()
    shift
    while [[ "$1" != "--" ]]; do
      vars+=("$1")
      shift
    done
    shift
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$dir" RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE="$(source_arg "$@")" \
      "${vars[@]}" bash "$helper" verify --item "$item" --ciphertext "${ec_out}/encryption-config.age" "$@"
  }
  match_dir="$(fresh_dir)"
  expect "encryption-config: verify reports MATCH" ok "result: MATCH" -- ec_verify "$match_dir" -- --source "$enc_source"
  if empty_dir "$match_dir"; then pass "encryption-config: cleanup after success"; else fail "success cleanup" "tmpdir not empty"; fi

  sed 's/"identity"/"aescbc"/' "$enc_source" >"${tmp}/ec-changed.json"
  chmod 0600 "${tmp}/ec-changed.json"
  differ_dir="$(fresh_dir)"
  expect "encryption-config: verify reports DIFFER for a changed configuration" 1 "result: DIFFER" -- \
    ec_verify "$differ_dir" -- --source "${tmp}/ec-changed.json"
  if empty_dir "$differ_dir"; then pass "encryption-config: cleanup after DIFFER"; else fail "DIFFER cleanup" "tmpdir not empty"; fi

  # cmp itself failing (exit status 2) must be reported as ERROR, never as MATCH.
  stub_cmp_dir="${tmp}/stub-cmp"
  mkdir -p "$stub_cmp_dir"
  printf '#!/usr/bin/env bash\nexit 2\n' >"${stub_cmp_dir}/cmp"
  chmod 0755 "${stub_cmp_dir}/cmp"
  error_dir="$(fresh_dir)"
  expect "encryption-config: verify reports ERROR when cmp fails" 1 "result: ERROR" -- \
    ec_verify "$error_dir" PATH="${stub_cmp_dir}:${PATH}" -- --source "$enc_source"
  if grep -qF "cmp -s exit status: 2" "${tmp}/out"; then pass "encryption-config: ERROR reports cmp exit status 2"; else fail "ERROR status" "cmp status not reported"; fi
  if empty_dir "$error_dir"; then pass "encryption-config: cleanup after ERROR"; else fail "ERROR cleanup" "tmpdir not empty"; fi

  age -R "${key_dir}/other-recipient" -o "${ec_out}/ec-other.age" -- "$enc_source"
  wrong_dir="$(fresh_dir)"
  expect "encryption-config: another recipient's ciphertext reports ERROR" 1 "result: ERROR" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$wrong_dir" bash "$helper" verify --item "$item" \
    --ciphertext "${ec_out}/ec-other.age" --source "$enc_source"
  if empty_dir "$wrong_dir"; then pass "encryption-config: cleanup after failed decryption"; else fail "failed decryption cleanup" "tmpdir not empty"; fi

  source_owner=0:0
  expect "encryption-config: verify with a valid ciphertext still refuses a wrongly owned source" 1 "not owned by root:root" -- \
    round env RECOVERY_MATERIAL_TEST_SOURCE_OWNER="$source_owner" RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" \
    bash "$helper" verify --item "$item" --ciphertext "${ec_out}/encryption-config.age" --source "$enc_source"
  source_owner=""
elif [[ "${RECOVERY_MATERIAL_REQUIRE_AGE:-}" == "1" ]]; then
  fail "group D round trips" "age and age-keygen v1.3.2 are required (RECOVERY_MATERIAL_REQUIRE_AGE=1)"
else
  skipped=$((skipped + 1))
  echo "skip group D round trips: age and age-keygen v1.3.2 are not on PATH"
fi

# S3 transfers with a private receipt: the version ID is never printed.
s3_tmp="$(fresh_dir)"
s3_private() { s3 env TMPDIR="$s3_tmp" "$@"; }
ec_date=2026-10-27
receipts="$(fresh_dir)"
write_header "${tmp}/ec-upload.age" X25519
EXTRA_FORBIDDEN=stub-version-1
expect "encryption-config: upload without --receipt is refused" 1 "upload needs --receipt" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date "$ec_date" --file "${tmp}/ec-upload.age"
if [[ ! -e "${store}/recovery_encryption-config_${ec_date}.age" ]]; then pass "encryption-config: refused upload sends nothing"; else fail "refused upload" "object stored"; fi
expect "encryption-config: invalid ciphertext header is refused by upload" 1 "not a single-recipient X25519 age ciphertext" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date "$ec_date" --file "${tmp}/no-mac.age" --receipt "${receipts}/bad.receipt"
open_receipts="$(fresh_dir)"
chmod 0750 "$open_receipts"
expect "encryption-config: group-accessible receipt directory is refused" 1 "receipt directory is accessible to group or others" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date "$ec_date" --file "${tmp}/ec-upload.age" --receipt "${open_receipts}/r"
ln -s "$receipts" "${tmp}/receipts-link"
expect "encryption-config: symlinked receipt directory is refused" 1 "receipt directory does not exist or is a symbolic link" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date "$ec_date" --file "${tmp}/ec-upload.age" --receipt "${tmp}/receipts-link/r"
expect "encryption-config: upload writes a private receipt" ok "version receipt: ${receipts}/ec.receipt" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date "$ec_date" --file "${tmp}/ec-upload.age" --receipt "${receipts}/ec.receipt"
if grep -qF "key: recovery/encryption-config/${ec_date}.age" "${tmp}/out" \
  && grep -qF "ciphertext sha256: $(sha256sum "${tmp}/ec-upload.age" | cut -d' ' -f1)" "${tmp}/out" \
  && [[ "$(stat -c '%a' "${receipts}/ec.receipt")" == "600" ]] \
  && [[ "$(cat "${receipts}/ec.receipt")" == "key: recovery/encryption-config/${ec_date}.age"$'\n'"version id: stub-version-1" ]]; then
  pass "encryption-config: upload prints key and ciphertext metadata only; receipt is mode 600 with key and version"
else
  fail "encryption-config: upload receipt" "metadata, receipt mode or receipt contents differ"
fi
expect "encryption-config: existing receipt is refused before any upload" 1 "the receipt already exists" -- \
  s3_private bash "$s3_helper" upload --item "$item" --date 2026-10-28 --file "${tmp}/ec-upload.age" --receipt "${receipts}/ec.receipt"
if [[ ! -e "${store}/recovery_encryption-config_2026-10-28.age" ]]; then pass "encryption-config: refused receipt sends nothing"; else fail "refused receipt" "object stored"; fi
# A receipt path that appears during the upload is never overwritten or followed.
expect "encryption-config: a receipt that appears during upload is not overwritten" 1 "receipt could not be written" -- \
  s3_private env FAKE_AWS_PLANT="${receipts}/raced.receipt" bash "$s3_helper" upload --item "$item" --date 2026-10-29 \
  --file "${tmp}/ec-upload.age" --receipt "${receipts}/raced.receipt"
if [[ "$(cat "${receipts}/raced.receipt")" == "planted" ]]; then pass "encryption-config: the raced receipt keeps its content"; else fail "raced receipt" "overwritten"; fi
# Every other kind of path that appears in the race is left alone and never opened:
# a FIFO (a write would block), a link to a device, a dangling link, a link to a file.
# timeout bounds a helper that wrongly opens the FIFO.
race=2026-10-30
ec_upload_sha="$(sha256sum -- "${tmp}/ec-upload.age" | cut -d' ' -f1)"
new_version_args=()
for kind in fifo devnull dangling filelink; do
  expect "encryption-config: a ${kind} receipt that appears during upload is not written" 1 "receipt could not be written" -- \
    s3_private env FAKE_AWS_PLANT="${receipts}/race-${kind}.receipt" FAKE_AWS_PLANT_KIND="$kind" \
    timeout 20 bash "$s3_helper" upload --item "$item" --date "$race" --file "${tmp}/ec-upload.age" \
    --receipt "${receipts}/race-${kind}.receipt" "${new_version_args[@]}"
  # The key exists after the first upload; later ones add versions explicitly.
  new_version_args=(--new-version --replaces-sha256 "$ec_upload_sha")
done
if [[ -p "${receipts}/race-fifo.receipt" && "$(readlink "${receipts}/race-devnull.receipt")" == /dev/null \
  && ! -e "${receipts}/race-dangling.receipt.absent" && "$(cat "${receipts}/race-filelink.receipt.target")" == "target" ]]; then
  pass "encryption-config: raced FIFO, links and link targets are unchanged"
else
  fail "encryption-config: raced paths" "a planted path or its target was changed"
fi
if [[ -z "$(find "$receipts" -maxdepth 1 -name '.receipt.*' -print -quit)" ]]; then
  pass "encryption-config: no temporary receipt is left behind"
else
  fail "encryption-config: temporary receipt" "left behind"
fi

expect "encryption-config: download by receipt reports MATCH" ok "result: MATCH" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/ec.receipt" \
  --out "${tmp}/ec-downloaded.age" --compare-with "${tmp}/ec-upload.age"
if grep -qF "version id: as recorded in the receipt" "${tmp}/out" && cmp -s "${tmp}/ec-downloaded.age" "${tmp}/ec-upload.age"; then
  pass "encryption-config: download is byte-identical and does not print the version ID"
else
  fail "encryption-config: download" "content differs or version line missing"
fi
expect "encryption-config: download by --version-id is refused" 1 "download needs --receipt" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --version-id stub-version-1 \
  --out "${tmp}/ec-d1.age" --compare-with "${tmp}/ec-upload.age"
expect "encryption-config: --version-id with --receipt is refused" 1 "exactly one of --version-id and --receipt" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --version-id stub-version-1 --receipt "${receipts}/ec.receipt" \
  --out "${tmp}/ec-d2.age" --compare-with "${tmp}/ec-upload.age"
expect "encryption-config: receipt for another object key is refused" 1 "receipt is for a different object key" -- \
  s3_private bash "$s3_helper" download --item "$item" --date 2026-10-26 --receipt "${receipts}/ec.receipt" \
  --out "${tmp}/ec-d3.age" --compare-with "${tmp}/ec-upload.age"
cp -- "${receipts}/ec.receipt" "${receipts}/open.receipt"
chmod 0644 "${receipts}/open.receipt"
expect "encryption-config: mode 644 receipt is refused" 1 "receipt must be mode 600 or 400" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/open.receipt" \
  --out "${tmp}/ec-d4.age" --compare-with "${tmp}/ec-upload.age"
printf 'key: recovery/encryption-config/%s.age\n' "$ec_date" >"${receipts}/short.receipt"
chmod 0600 "${receipts}/short.receipt"
expect "encryption-config: malformed receipt is refused" 1 "receipt is malformed" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/short.receipt" \
  --out "${tmp}/ec-d5.age" --compare-with "${tmp}/ec-upload.age"
printf 'key: recovery/encryption-config/%s.age\nversion id: stub-version-1\ntrailing' "$ec_date" >"${receipts}/trailing.receipt"
chmod 0600 "${receipts}/trailing.receipt"
expect "encryption-config: receipt with trailing text is refused" 1 "receipt is malformed" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/trailing.receipt" \
  --out "${tmp}/ec-d5b.age" --compare-with "${tmp}/ec-upload.age"
ln -s "${receipts}/ec.receipt" "${receipts}/link.receipt"
expect "encryption-config: symlinked receipt is refused" 1 "not a regular file, or a symbolic link" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/link.receipt" \
  --out "${tmp}/ec-d6.age" --compare-with "${tmp}/ec-upload.age"
expect "encryption-config: mismatched returned version is refused" 1 "different version than requested" -- \
  s3_private env FAKE_AWS_RETURNED_VERSION=stub-version-2 bash "$s3_helper" download --item "$item" --date "$ec_date" \
  --receipt "${receipts}/ec.receipt" --out "${tmp}/ec-d7.age" --compare-with "${tmp}/ec-upload.age"
if [[ ! -e "${tmp}/ec-d7.age" ]]; then pass "encryption-config: rejected version is not copied to --out"; else fail "rejected version" "output left"; fi
printf 'key: recovery/encryption-config/%s.age\nversion id: other-version\n' "$ec_date" >"${receipts}/other.receipt"
chmod 0600 "${receipts}/other.receipt"
expect "encryption-config: unknown version is reported by code only" 1 "get-object failed: NoSuchVersion" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/other.receipt" \
  --out "${tmp}/ec-d8.age" --compare-with "${tmp}/ec-upload.age"
if ! grep -qF "other-version" "${tmp}/out"; then pass "encryption-config: unknown version ID is not printed"; else fail "unknown version" "version ID printed"; fi
write_header "${store}/recovery_encryption-config_${ec_date}.age" X25519
printf 'tampered' >>"${store}/recovery_encryption-config_${ec_date}.age"
expect "encryption-config: changed object reports DIFFER" 1 "result: DIFFER" -- \
  s3_private bash "$s3_helper" download --item "$item" --date "$ec_date" --receipt "${receipts}/ec.receipt" \
  --out "${tmp}/ec-d9.age" --compare-with "${tmp}/ec-upload.age"
EXTRA_FORBIDDEN=""
if empty_dir "$s3_tmp"; then pass "encryption-config: S3 work directories removed after success and failure"; else fail "S3 cleanup" "work directory left behind"; fi

# --- group E: run directories and scoped cleanup ----------------------------------------
echo "Group E: run directories and scoped cleanup"
# start-run and cleanup have no test mode: they run exactly as in production, as the
# invoking (non-root) user. $1 is the helper to run, so that mutants can be tested.
run_helper() {
  local helper_path="$1"
  shift
  env -u RECOVERY_MATERIAL_TEST -u RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE bash "$helper_path" "$@"
}
rm_helper() { run_helper "$helper" "$@"; }

# Stands in for ~/hc-recovery, holding ciphertexts retained from an earlier run under
# the same names a new run uses, with an older timestamp.
e_home="$(fresh_dir)"
retained=("${e_home}/k3s-server-token.age" "${e_home}/recovery-inventory.age" "${e_home}/recovery-inventory.downloaded.age")
keep_args=()
for file in "${retained[@]}"; do
  write_header "$file" X25519
  touch -d '2026-10-16 12:00:00' "$file"
  keep_args+=(--keep "$file")
done
retained_sums="$(sha256sum -- "${retained[@]}")"
retained_unchanged() {
  [[ "$(sha256sum -- "${retained[@]}" 2>/dev/null)" == "$retained_sums" ]]
}

# new_run HELPER NAME FILE...: a new run directory under e_home, made by start-run,
# holding fresh ciphertext-shaped files with the given names. Prints its path.
new_run() {
  local helper_path="$1" dir="${e_home}/$2" name
  shift 2
  run_helper "$helper_path" start-run --dir "$dir" >/dev/null
  for name in "$@"; do
    write_header "${dir}/${name}" X25519
  done
  printf '%s' "$dir"
}

e_run="${e_home}/run-start"
expect "cleanup: start-run creates the run directory" ok "result: PASS" -- rm_helper start-run --dir "$e_run"
if [[ "$(stat -c '%a %u' -- "$e_run")" == "700 $(id -u)" && -f "${e_run}/.recovery-run" ]]; then
  pass "cleanup: the run directory is mode 700 with a run marker"
else
  fail "start-run" "run directory mode or marker wrong"
fi
expect "cleanup: start-run refuses an existing directory" 1 "already exists" -- rm_helper start-run --dir "$e_run"
expect "cleanup: start-run refuses a relative path" 1 "absolute, normalized path" -- rm_helper start-run --dir run-relative
ln -s "$e_home" "${tmp}/home-link"
expect "cleanup: start-run refuses a symbolic-link parent" 1 "parent directory does not exist or is a symbolic link" -- \
  rm_helper start-run --dir "${tmp}/home-link/run-x"
expect "cleanup: a run holding only its marker is removed" ok "run directory: absent" -- rm_helper cleanup --dir "$e_run"

# The live layout: run files in the run directory, retained ciphertexts beside it.
e_run="$(new_run "$helper" run-ok k3s-server-token.age k3s-server-token.downloaded.age recovery-inventory.age \
  recovery-inventory.downloaded.age identity-archive.age)"
expect "cleanup: removes the listed run files and keeps the retained ciphertexts" ok "result: PASS" -- \
  rm_helper cleanup --dir "$e_run" --remove k3s-server-token.age --remove k3s-server-token.downloaded.age \
  --remove recovery-inventory.age --remove recovery-inventory.downloaded.age --remove identity-archive.age "${keep_args[@]}"
if [[ ! -e "$e_run" ]] && retained_unchanged && [[ "$(grep -c '^retained unchanged: ' "${tmp}/out")" -eq 3 ]]; then
  pass "cleanup: run directory absent; each retained ciphertext reported and byte-identical"
else
  fail "cleanup" "run directory left, or a retained ciphertext missing, changed or unreported"
fi

# Regression scenarios. Each returns 0 only when the cleanup refuses with the named
# guard and removes nothing. They run against the real helper and against mutants.
#
# A retained ciphertext copied into a run directory with its old timestamp, under a
# run file name, and listed for removal.
scenario_retained_copy_listed() {
  local helper_path="$1" dir
  dir="$(new_run "$helper_path" "run-listed-${RANDOM}" k3s-server-token.downloaded.age)"
  cp -p -- "${e_home}/k3s-server-token.age" "${dir}/k3s-server-token.age"
  run_helper "$helper_path" cleanup --dir "$dir" --remove k3s-server-token.age \
    --remove k3s-server-token.downloaded.age "${keep_args[@]}" >"${tmp}/scenario" 2>&1 && return 1
  grep -qF "predates the run directory" "${tmp}/scenario" \
    && [[ -f "${dir}/k3s-server-token.age" && -f "${dir}/k3s-server-token.downloaded.age" ]] && retained_unchanged
}
# The same kind of copy present but not listed: an unexpected entry.
scenario_retained_copy_unlisted() {
  local helper_path="$1" dir
  dir="$(new_run "$helper_path" "run-unlisted-${RANDOM}" k3s-server-token.downloaded.age)"
  cp -p -- "${e_home}/recovery-inventory.age" "${dir}/recovery-inventory.age"
  run_helper "$helper_path" cleanup --dir "$dir" --remove k3s-server-token.downloaded.age >"${tmp}/scenario" 2>&1 && return 1
  grep -qF "unexpected entry in the run directory" "${tmp}/scenario" \
    && [[ -f "${dir}/recovery-inventory.age" && -f "${dir}/k3s-server-token.downloaded.age" ]] && retained_unchanged
}
# A name that reaches out of the run directory to a retained ciphertext.
scenario_parent_traversal() {
  local helper_path="$1" dir
  dir="$(new_run "$helper_path" "run-traversal-${RANDOM}")"
  run_helper "$helper_path" cleanup --dir "$dir" --remove ../k3s-server-token.age >"${tmp}/scenario" 2>&1 && return 1
  grep -qF "not a run file name" "${tmp}/scenario" && [[ -f "${dir}/.recovery-run" ]] && retained_unchanged
}
# The directory of retained ciphertexts itself, given as the run directory.
scenario_parent_as_run() {
  local helper_path="$1"
  run_helper "$helper_path" cleanup --dir "$e_home" --remove k3s-server-token.age \
    --remove recovery-inventory.age --remove recovery-inventory.downloaded.age >"${tmp}/scenario" 2>&1 && return 1
  grep -qF "not a run directory" "${tmp}/scenario" && retained_unchanged
}
for scenario in scenario_retained_copy_listed scenario_retained_copy_unlisted scenario_parent_traversal scenario_parent_as_run; do
  if "$scenario" "$helper"; then
    pass "cleanup: ${scenario#scenario_}: refused, nothing removed, retained ciphertexts unchanged"
  else
    fail "cleanup: ${scenario#scenario_}" "not refused by its guard, or a file was removed or changed"
    sed 's/^/     | /' "${tmp}/scenario"
  fi
done

# Mutation tests: with each guard disabled, its scenario must fail, which shows that
# the scenario depends on that guard.
mutant_dir="${tmp}/mutant/scripts"
mkdir -p "$mutant_dir"
mutant_case() {
  local label="$1" message="$2" scenario="$3" mutant="${mutant_dir}/recovery-material.sh"
  sed "s/|| die \"${message}/|| : \"${message}/" "$helper" >"$mutant"
  if cmp -s -- "$helper" "$mutant"; then
    fail "cleanup mutant: ${label}" "mutation anchor not found: ${message}"
  elif "$scenario" "$mutant"; then
    fail "cleanup mutant: ${label}" "the scenario passed with the guard disabled"
  else
    pass "cleanup mutant: ${label}: killed by ${scenario#scenario_}"
  fi
}
mutant_case "no pre-run timestamp guard" "run file predates the run directory" scenario_retained_copy_listed
mutant_case "no exact-contents guard" "unexpected entry in the run directory" scenario_retained_copy_unlisted
mutant_case "no run-file name guard" "not a run file name" scenario_parent_traversal
mutant_case "no run-marker guard" "not a run directory" scenario_parent_as_run

# Refusals. Each must remove nothing.
e_run="$(new_run "$helper" run-refuse k3s-server-token.age identity-archive.age)"
refuse() {
  local name="$1" message="$2"
  shift 2
  expect "cleanup: refuses ${name}" 1 "$message" -- rm_helper cleanup "$@"
  if [[ -f "${e_run}/k3s-server-token.age" && -f "${e_run}/identity-archive.age" && -f "${e_run}/.recovery-run" ]] \
    && retained_unchanged; then
    pass "cleanup: nothing removed after refusing ${name}"
  else
    fail "cleanup: ${name}" "a file was removed despite the refusal"
  fi
}
refuse "a wildcard name" "not a run file name" --dir "$e_run" --remove '*.age'
refuse "an unrelated name" "not a run file name" --dir "$e_run" --remove notes.age
refuse "a duplicate name" "listed more than once" --dir "$e_run" --remove k3s-server-token.age \
  --remove k3s-server-token.age --remove identity-archive.age
refuse "a missing run file" "does not exist or is not a regular file" --dir "$e_run" --remove k3s-server-token.age \
  --remove identity-archive.age --remove grafana-admin.age
refuse "a run directory with a trailing slash" "absolute, normalized path" --dir "${e_run}/" --remove k3s-server-token.age
refuse "a run directory with a .. component" "absolute, normalized path" --dir "${e_run}/../run-refuse" \
  --remove k3s-server-token.age
ln -s "$e_run" "${e_home}/run-link"
refuse "a symbolic-link run directory" "does not exist or is a symbolic link" --dir "${e_home}/run-link" \
  --remove k3s-server-token.age --remove identity-archive.age
rm -f -- "${e_home}/run-link"
refuse "a run directory under a symbolic-link path" "path contains a symbolic link" --dir "${tmp}/home-link/run-refuse" \
  --remove k3s-server-token.age --remove identity-archive.age
refuse "a kept file inside the run directory" "must not be inside the run directory" --dir "$e_run" \
  --remove identity-archive.age --keep "${e_run}/k3s-server-token.age"
refuse "a missing kept file" "kept file does not exist" --dir "$e_run" --remove k3s-server-token.age \
  --remove identity-archive.age --keep "${e_home}/grafana-admin.age"
ln -s "${e_home}/k3s-server-token.age" "${tmp}/kept-link.age"
refuse "a symbolic-link kept file" "or is a symbolic link" --dir "$e_run" \
  --remove k3s-server-token.age --remove identity-archive.age --keep "${tmp}/kept-link.age"
refuse "an unknown argument" "unknown argument" --dir "$e_run" --remove k3s-server-token.age --all yes
mkdir "${e_run}/nested"
refuse "an unexpected subdirectory" "unexpected entry in the run directory" --dir "$e_run" \
  --remove k3s-server-token.age --remove identity-archive.age
rmdir "${e_run}/nested"
chmod 0750 "$e_run"
refuse "a run directory that is not mode 700" "must be mode 700 and owned by you" --dir "$e_run" \
  --remove k3s-server-token.age --remove identity-archive.age
chmod 0700 "$e_run"
mv "${e_run}/.recovery-run" "${tmp}/marker"
ln -s "${tmp}/marker" "${e_run}/.recovery-run"
expect "cleanup: refuses a symbolic-link run marker" 1 "not a run directory" -- \
  rm_helper cleanup --dir "$e_run" --remove k3s-server-token.age --remove identity-archive.age
rm -f -- "${e_run}/.recovery-run"
mv "${tmp}/marker" "${e_run}/.recovery-run"

# Links in a run directory that point at a retained ciphertext.
e_links="$(new_run "$helper" run-links)"
ln -s "${e_home}/k3s-server-token.age" "${e_links}/k3s-server-token.age"
ln "${e_home}/recovery-inventory.age" "${e_links}/recovery-inventory.age"
expect "cleanup: refuses a symbolic link to a retained ciphertext" 1 "run file is a symbolic link" -- \
  rm_helper cleanup --dir "$e_links" --remove k3s-server-token.age
expect "cleanup: refuses a hard link to a retained ciphertext" 1 "has other hard links" -- \
  rm_helper cleanup --dir "$e_links" --remove recovery-inventory.age
if [[ -L "${e_links}/k3s-server-token.age" && -f "${e_links}/recovery-inventory.age" ]] && retained_unchanged; then
  pass "cleanup: links and retained ciphertexts untouched after the link refusals"
else
  fail "cleanup links" "a link or retained ciphertext was removed or changed"
fi

# --- group F: decrypt-inventory (updating an existing inventory) ------------------------
echo "Group F: decrypt-inventory (inventory update)"
template="${repo_root}/docs/runbooks/recovery-material-inventory-template.md"
f_src="$(fresh_dir)"   # holds the previous inventory ciphertext and the archive, outside the tmpfs
# A header-only stand-in for the passphrase-encrypted archive: test mode decrypts with the
# throwaway test identity instead, because it cannot answer a passphrase prompt.
write_header "${f_src}/archive.age" scrypt
archive_sum="$(sha256sum -- "${f_src}/archive.age" | cut -d' ' -f1)"

# The inventory-encryption guard needs no decryption.
f_guard="$(fresh_dir)"
install -m 0600 -- "$template" "${f_guard}/recovery-material-inventory.md"
for leftover in previous-inventory.md previous-inventory.age identity-archive.age; do
  : >"${f_guard}/${leftover}"
  expect "decrypt-inventory: encrypt refuses the inventory beside ${leftover}" 1 "remove ${leftover} from the inventory directory" -- \
    run_test_mode bash "$helper" encrypt --item recovery-inventory --source "${f_guard}/recovery-material-inventory.md" \
    --out "${tmp}/f-guard-${leftover}.age"
  rm -f -- "${f_guard}/${leftover}"
  if [[ ! -e "${tmp}/f-guard-${leftover}.age" ]]; then
    pass "decrypt-inventory: no ciphertext written beside ${leftover}"
  else
    fail "encrypt guard" "ciphertext written beside ${leftover}"
  fi
done

if (( real_age_ok )); then
  f_key="$(fresh_dir)"
  age-keygen -o "${f_key}/identity" 2>/dev/null
  age-keygen -y "${f_key}/identity" >"${f_key}/recipient"
  age-keygen -o "${f_key}/other-identity" 2>/dev/null
  # The previous inventory: the template plus a sentinel row that must never be printed.
  { cat -- "$template"; printf '\n| Note | %s |\n' "\`${sentinel}\`"; } >"${f_key}/previous.md"
  age -R "${f_key}/recipient" -o "${f_src}/previous.age" -- "${f_key}/previous.md"
  prior="${f_src}/previous.age"
  prior_sum="$(sha256sum -- "$prior" | cut -d' ' -f1)"
  prior_state="$(stat -c '%i %s %y' -- "$prior") ${prior_sum}"
  prior_unchanged() {
    [[ "$(stat -c '%i %s %y' -- "$prior" 2>/dev/null) $(sha256sum -- "$prior" 2>/dev/null | cut -d' ' -f1)" == "$prior_state" ]]
  }
  # dec HELPER INVENTORY-DIR [ARG...]: decrypt-inventory in test mode; later arguments
  # override the defaults. The archive SHA-256 is given in upper case, as the runbook shows it.
  dec() {
    local helper_path="$1" dir="$2"
    shift 2
    env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="${f_key}/recipient" \
      RECOVERY_MATERIAL_TEST_IDENTITY="${F_IDENTITY:-${f_key}/identity}" \
      bash "$helper_path" decrypt-inventory --inventory-dir "$dir" --ciphertext "$prior" --ciphertext-sha256 "$prior_sum" \
      --identity-archive "${f_src}/archive.age" --archive-sha256 "${archive_sum^^}" "$@"
  }
  inventory_encrypt() {
    env RECOVERY_MATERIAL_TEST=1 RECOVERY_MATERIAL_TEST_RECIPIENT="${f_key}/recipient" bash "$1" encrypt \
      --item recovery-inventory --source "$2" --out "$3"
  }

  f_inv="$(fresh_dir)"
  expect "decrypt-inventory: decrypts the previous inventory into the inventory directory" ok "result: PASS" -- \
    dec "$helper" "$f_inv"
  if [[ -f "${f_inv}/previous-inventory.md" && ! -L "${f_inv}/previous-inventory.md" \
    && "$(stat -c '%a %h' -- "${f_inv}/previous-inventory.md")" == "600 1" ]] \
    && cmp -s -- "${f_inv}/previous-inventory.md" "${f_key}/previous.md" \
    && [[ "$(ls -A -- "$f_inv")" == "previous-inventory.md" ]]; then
    pass "decrypt-inventory: mode 600, byte-identical, and only the plaintext is left (copies removed)"
  else
    fail "decrypt-inventory" "plaintext missing, wrong mode or content, or a copy left behind"
  fi
  if prior_unchanged; then pass "decrypt-inventory: the previous inventory ciphertext is unchanged"; else fail "decrypt-inventory" "prior changed"; fi
  expect "decrypt-inventory: refuses an existing previous plaintext" 1 "already present in the inventory directory" -- \
    dec "$helper" "$f_inv"
  if cmp -s -- "${f_inv}/previous-inventory.md" "${f_key}/previous.md"; then
    pass "decrypt-inventory: the existing previous plaintext is not replaced"
  else
    fail "decrypt-inventory" "existing previous plaintext was changed"
  fi

  # The update flow: replacement, removal of the previous plaintext, then encryption.
  install -m 0600 -- "${f_inv}/previous-inventory.md" "${f_inv}/recovery-material-inventory.md"
  expect "decrypt-inventory: encrypt refuses while the previous plaintext remains" 1 "remove previous-inventory.md" -- \
    inventory_encrypt "$helper" "${f_inv}/recovery-material-inventory.md" "${tmp}/f-new.age"
  rm -f -- "${f_inv}/previous-inventory.md"
  expect "decrypt-inventory: encrypt succeeds once the previous plaintext is removed" ok "ciphertext sha256: " -- \
    inventory_encrypt "$helper" "${f_inv}/recovery-material-inventory.md" "${tmp}/f-new.age"
  expect "decrypt-inventory: encrypt never overwrites the previous inventory ciphertext" 1 "output already exists" -- \
    inventory_encrypt "$helper" "${f_inv}/recovery-material-inventory.md" "$prior"
  if prior_unchanged; then pass "decrypt-inventory: previous ciphertext unchanged after the update flow"; else fail "update flow" "prior changed"; fi

  # Refusals before decryption. Each must leave the inventory directory empty.
  f_refuse() {
    local name="$1" message="$2" dir
    shift 2
    dir="$(fresh_dir)"
    expect "decrypt-inventory: refuses ${name}" 1 "$message" -- dec "$helper" "$dir" "$@"
    if empty_dir "$dir" && prior_unchanged; then
      pass "decrypt-inventory: nothing left after refusing ${name}"
    else
      fail "decrypt-inventory: ${name}" "files left in the inventory directory, or the previous ciphertext changed"
    fi
  }
  f_refuse "a wrong ciphertext SHA-256" "previous inventory ciphertext does not have the expected SHA-256" \
    --ciphertext-sha256 "$archive_sum"
  f_refuse "a wrong archive SHA-256" "identity archive does not have the expected SHA-256" --archive-sha256 "$prior_sum"
  f_refuse "a malformed SHA-256" "64 hexadecimal characters" --ciphertext-sha256 abc123
  write_header "${f_src}/not-scrypt.age" X25519
  f_refuse "an archive that is not passphrase-encrypted" "not a passphrase-encrypted age file" \
    --identity-archive "${f_src}/not-scrypt.age" --archive-sha256 "$(sha256sum -- "${f_src}/not-scrypt.age" | cut -d' ' -f1)"
  write_header "${f_src}/two-stanzas.age" X25519 X25519
  f_refuse "a ciphertext with two stanzas" "previous inventory ciphertext header check failed" \
    --ciphertext "${f_src}/two-stanzas.age" --ciphertext-sha256 "$(sha256sum -- "${f_src}/two-stanzas.age" | cut -d' ' -f1)"
  ln -s "$prior" "${f_src}/prior-link.age"
  f_refuse "a symbolic-link ciphertext" "ciphertext is a symbolic link" --ciphertext "${f_src}/prior-link.age"
  ln -s "$f_src" "${tmp}/src-link"
  f_refuse "a ciphertext under a symbolic-link path" "path contains a symbolic link" --ciphertext "${tmp}/src-link/previous.age"
  f_refuse "a relative ciphertext path" "must be absolute and normalized" --ciphertext previous.age
  f_refuse "a missing archive" "identity archive does not exist" --identity-archive "${f_src}/absent.age"
  f_refuse "an unknown argument" "unknown argument" --out "${tmp}/elsewhere.md"
  f_in="$(fresh_dir)"
  cp -- "$prior" "${f_in}/previous-copy.age"
  expect "decrypt-inventory: refuses a ciphertext inside the inventory directory" 1 "must not be inside the inventory directory" -- \
    dec "$helper" "$f_in" --ciphertext "${f_in}/previous-copy.age"
  f_mode="$(fresh_dir)"
  chmod 0750 "$f_mode"
  expect "decrypt-inventory: refuses an inventory directory that is not mode 700" 1 "must be mode 700 and owned by you" -- \
    dec "$helper" "$f_mode"
  ln -s "$(fresh_dir)" "${tmp}/inv-link"
  expect "decrypt-inventory: refuses a symbolic-link inventory directory" 1 "does not exist or is a symbolic link" -- \
    dec "$helper" "${tmp}/inv-link"
  f_rep="$(fresh_dir)"
  install -m 0600 -- "$template" "${f_rep}/recovery-material-inventory.md"
  expect "decrypt-inventory: refuses an existing replacement" 1 "already present in the inventory directory" -- \
    dec "$helper" "$f_rep"

  # Outside test mode, the inventory directory must be a tmpfs mount point.
  not_tmpfs() {
    env -u RECOVERY_MATERIAL_TEST -u RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE bash "$1" decrypt-inventory \
      --inventory-dir "$2" --ciphertext "$prior" --ciphertext-sha256 "$prior_sum" \
      --identity-archive "${f_src}/archive.age" --archive-sha256 "$archive_sum" </dev/null
  }
  f_prod="$(fresh_dir)"
  expect "decrypt-inventory: refuses an inventory directory that is not a tmpfs (production mode)" 1 "not a tmpfs mount point" -- \
    not_tmpfs "$helper" "$f_prod"
  if empty_dir "$f_prod"; then pass "decrypt-inventory: nothing written to a directory that is not a tmpfs"; else fail "production tmpfs gate" "files written"; fi

  # Failures after decryption starts. Each must remove the plaintext and the copies.
  grep -v '| Decryption comparison |' -- "${f_key}/previous.md" >"${f_key}/missing-row.md"
  age -R "${f_key}/recipient" -o "${f_src}/missing-row.age" -- "${f_key}/missing-row.md"
  : >"${f_key}/empty.md"
  age -R "${f_key}/recipient" -o "${f_src}/empty.age" -- "${f_key}/empty.md"
  dec_file() {
    dec "$1" "$2" --ciphertext "${f_src}/$3" --ciphertext-sha256 "$(sha256sum -- "${f_src}/$3" | cut -d' ' -f1)"
  }
  dec_other_identity() { F_IDENTITY="${f_key}/other-identity" dec "$1" "$2"; }
  dec_missing_row() { dec_file "$1" "$2" missing-row.age; }
  dec_empty() { dec_file "$1" "$2" empty.age; }
  f_after() {
    local name="$1" message="$2" runner="$3" dir
    dir="$(fresh_dir)"
    expect "decrypt-inventory: ${name}" 1 "$message" -- "$runner" "$helper" "$dir"
    if empty_dir "$dir"; then pass "decrypt-inventory: no plaintext or copy left after: ${name}"; else fail "decrypt-inventory: ${name}" "files left behind"; fi
  }
  f_after "fails with the wrong identity" "age decryption failed" dec_other_identity
  f_after "refuses a previous inventory that fails the inventory check" "failed the inventory check" dec_missing_row
  f_after "refuses an empty previous inventory" "missing, empty or not a regular file" dec_empty

  # Mutation tests: each scenario holds for the real helper and fails with its guard disabled.
  scenario_wrong_sum() {
    local dir
    dir="$(fresh_dir)"
    dec "$1" "$dir" --ciphertext-sha256 "$archive_sum" >"${tmp}/scenario" 2>&1 && return 1
    grep -qF "does not have the expected SHA-256" "${tmp}/scenario" && empty_dir "$dir"
  }
  scenario_failed_check() {
    local dir
    dir="$(fresh_dir)"
    dec_missing_row "$1" "$dir" >"${tmp}/scenario" 2>&1 && return 1
    grep -qF "failed the inventory check" "${tmp}/scenario" && empty_dir "$dir"
  }
  scenario_not_tmpfs() {
    local dir
    dir="$(fresh_dir)"
    not_tmpfs "$1" "$dir" >"${tmp}/scenario" 2>&1 && return 1
    grep -qF "not a tmpfs mount point" "${tmp}/scenario" && empty_dir "$dir"
  }
  scenario_encrypt_beside_previous() {
    local dir
    dir="$(fresh_dir)"
    install -m 0600 -- "$template" "${dir}/recovery-material-inventory.md"
    : >"${dir}/previous-inventory.md"
    inventory_encrypt "$1" "${dir}/recovery-material-inventory.md" "${dir}/new.age" >"${tmp}/scenario" 2>&1 && return 1
    [[ ! -e "${dir}/new.age" ]]
  }
  f_mutant="${mutant_dir}/recovery-material.sh"
  # decrypt-inventory runs the inventory check from the helper's own directory.
  cp -- "${repo_root}/scripts/validate-recovery-material.py" "${mutant_dir}/"
  f_mutant_case() {
    local label="$1" expression="$2" scenario="$3"
    sed "$expression" "$helper" >"$f_mutant"
    if cmp -s -- "$helper" "$f_mutant"; then
      fail "decrypt-inventory mutant: ${label}" "mutation anchor not found"
    elif ! "$scenario" "$helper"; then
      fail "decrypt-inventory mutant: ${label}" "the scenario fails against the real helper"
    elif "$scenario" "$f_mutant"; then
      fail "decrypt-inventory mutant: ${label}" "the scenario passed with the guard disabled"
    else
      pass "decrypt-inventory mutant: ${label}: killed by ${scenario#scenario_}"
    fi
  }
  f_mutant_case "no ciphertext SHA-256 guard" 's/|| die "the previous inventory ciphertext does not have/|| : "/' scenario_wrong_sum
  f_mutant_case "plaintext kept after a failed check" 's/if (( ! decrypt_done )); then/if false; then/' scenario_failed_check
  f_mutant_case "no tmpfs guard" 's/|| die "the inventory directory is not a tmpfs mount point/|| : "/' scenario_not_tmpfs
  f_mutant_case "no encrypt guard for the previous plaintext" \
    's/|| die "remove \(.*\) from the inventory directory before encrypting/|| : "\1/' scenario_encrypt_beside_previous
  if prior_unchanged; then pass "decrypt-inventory: previous ciphertext unchanged after every case and mutant"; else fail "decrypt-inventory" "prior changed"; fi
elif [[ "${RECOVERY_MATERIAL_REQUIRE_AGE:-}" == "1" ]]; then
  fail "group F" "age and age-keygen v1.3.2 are required (RECOVERY_MATERIAL_REQUIRE_AGE=1)"
else
  skipped=$((skipped + 1))
  echo "skip group F decryption cases: age and age-keygen v1.3.2 are not on PATH"
fi

# TERM during decryption, with the stub age, which writes a stand-in and sleeps.
write_header "${f_src}/stub-prior.age" X25519
f_term="$(fresh_dir)"
f_pidfile="${tmp}/stub-age-decrypt.pid"
set +e
run_test_mode env PATH="$stub_path" STUB_AGE_SLEEP_PIDFILE="$f_pidfile" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
  bash "$helper" decrypt-inventory --inventory-dir "$f_term" --ciphertext "${f_src}/stub-prior.age" \
  --ciphertext-sha256 "$(sha256sum -- "${f_src}/stub-prior.age" | cut -d' ' -f1)" \
  --identity-archive "${f_src}/archive.age" --archive-sha256 "$archive_sum" >"${tmp}/f-term.out" 2>&1 &
f_helper_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$f_pidfile" ]] && break
  sleep 0.1
done
f_seen="$(find "$f_term" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')"
f_helper_bash="$(pgrep -P "$f_helper_pid" -f recovery-material.sh || echo "$f_helper_pid")"
kill -TERM "$f_helper_bash" 2>/dev/null
kill -TERM "$(cat "$f_pidfile" 2>/dev/null)" 2>/dev/null
wait "$f_helper_pid"
f_rc=$?
set -e
if [[ "$f_seen" == "identity-archive.age previous-inventory.age previous-inventory.md " && "$f_rc" -eq 143 ]] \
  && empty_dir "$f_term" && ! leaked "${tmp}/f-term.out"; then
  pass "decrypt-inventory: TERM during decryption removes the plaintext and copies and exits 143"
else
  fail "decrypt-inventory TERM" "exit ${f_rc}; seen before: ${f_seen}; left: $(find "$f_term" -mindepth 1 -maxdepth 1 -printf '%f ')"
fi

# --- group G: stage3-p2-snapshot (the interim manual p2 copy) -----------------------------
echo "Group G: stage3-p2-snapshot (interim manual p2 snapshot copy)"
p2_item=stage3-p2-snapshot
p2_label=p2-post-encryption
p2_name="stage3-p2-post-encryption-20261029t144551z-k3s01-1793285175"
me_user="$(id -un)"
me_uid="$(id -u)"
fake_sum="$(printf 'ab%.0s' $(seq 32))"

# Stand-in for runuser -u USER -- COMMAND...: records the user and runs COMMAND as the
# test user. STUB_RUNUSER_CHMOD and STUB_RUNUSER_LINK then damage the created file, as
# a broken ownership transition would.
stub_runuser_dir="${tmp}/stub-runuser"
mkdir -p "$stub_runuser_dir"
cat >"${stub_runuser_dir}/runuser" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" && "${3:-}" == "--" ]] || { echo "stub runuser: unexpected arguments" >&2; exit 2; }
printf '%s\n' "$2" >>"${STUB_RUNUSER_LOG:?}"
shift 3
target="${!#}"
"$@"
rc=$?
[[ -n "${STUB_RUNUSER_CHMOD:-}" ]] && chmod "$STUB_RUNUSER_CHMOD" -- "$target"
[[ -n "${STUB_RUNUSER_LINK:-}" ]] && ln -- "$target" "$STUB_RUNUSER_LINK"
exit "$rc"
EOF
chmod 0755 "${stub_runuser_dir}/runuser"
runuser_log="${tmp}/runuser.log"

# p2_checkpoints [RECORD...]: the checkpoints file, with the earlier Stage 3 records
# and then the given ones.
p2_checkpoints() {
  {
    printf '1793223427 baseline stage3-baseline-20261028t213642z-k3s01-1793223427 12820512 %s token=present\n' "$fake_sum"
    printf '1793223582 p0-pre-enable stage3-p0-pre-enable-20261028t213918z-k3s01-1793223582 12820512 %s token=present\n' "$fake_sum"
    printf '1793282417 p1-pre-rotate stage3-p1-pre-rotate-20261029t135952z-k3s01-1793282417 9941024 %s token=present\n' "$fake_sum"
    (( $# )) && printf '%s\n' "$@"
  } >"$fx_ckpt"
  chmod 0600 "$fx_ckpt"
}
# p2_fixture: a fresh snapshot directory and checkpoints file, standing in for
# /var/lib/rancher/k3s/server/db/snapshots and /var/lib/homelab-secrets-encryption,
# with a random p2 snapshot whose SHA-256 is recorded and must never be printed.
p2_fixture() {
  fx_root="$(fresh_dir)"
  fx_snapdir="${fx_root}/snapshots"
  mkdir -m 0700 "$fx_snapdir" "${fx_root}/state"
  fx_snap="${fx_snapdir}/${p2_name}"
  { head -c 200000 /dev/urandom; printf '%s\n' "$sentinel"; } >"$fx_snap"
  chmod 0600 "$fx_snap"
  fx_sha="$(sha256sum -- "$fx_snap" | cut -d' ' -f1)"
  fx_size="$(stat -c %s -- "$fx_snap")"
  fx_mtime="$(stat -c %Y -- "$fx_snap")"
  never_print+=("$fx_sha")
  fx_ckpt="${fx_root}/state/checkpoints"
  fx_record="${fx_mtime} ${p2_label} ${p2_name} ${fx_size} ${fx_sha} token=present"
  p2_checkpoints "$fx_record"
  fx_out="$(fresh_dir)"
}
# p2 [NAME=VALUE...] -- ARGS: the helper (or $p2_helper) in test mode, bound to the
# current fixture, as under sudo from the test user through the stub runuser.
p2() {
  local vars=()
  while [[ "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift
  run_test_mode env PATH="${stub_runuser_dir}:${p2_age_path:-$stub_path}" STUB_RUNUSER_LOG="$runuser_log" \
    RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR="$fx_snapdir" RECOVERY_MATERIAL_TEST_CHECKPOINTS="$fx_ckpt" \
    RECOVERY_MATERIAL_TEST_SUDO_USER="$me_user" RECOVERY_MATERIAL_TEST_SUDO_UID="$me_uid" \
    "${vars[@]}" bash "${p2_helper:-$helper}" "$@"
}
p2_encrypt() {
  local vars=()
  while [[ "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift
  p2 "${vars[@]}" -- encrypt --item "$p2_item" "$@"
}
p2_verify() {
  local vars=()
  while [[ "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift
  p2 RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" \
    "${vars[@]}" -- verify --item "$p2_item" "$@"
}
# refused MESSAGE -- COMMAND...: succeeds only if COMMAND fails and prints MESSAGE.
refused() {
  local message="$1"
  shift 2
  ! "$@" >"${tmp}/refused.out" 2>&1 && grep -qF -- "$message" "${tmp}/refused.out"
}

p2_fixture
expect "p2: the checkpointed snapshot reaches age (stub refuses real work)" 1 "$reaches_age" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
if empty_dir "$fx_out" && [[ "$(tail -n 1 "$runuser_log")" == "$me_user" ]]; then
  pass "p2: encrypt writes through runuser as the operator, and a failed encryption leaves no output"
else
  fail "p2: runuser and failed encryption" "runuser not used as the operator, or output left"
fi
if grep -qxF "SNAPSHOT_DIR=\"/var/lib/rancher/k3s/server/db/snapshots\"" "$helper" \
  && grep -qxF "CHECKPOINTS_FILE=\"/var/lib/homelab-secrets-encryption/checkpoints\"" "$helper" \
  && grep -qxF "SNAPSHOT_MAX_BYTES=\$(( 64 * 1024 * 1024 ))" "$helper"; then
  pass "p2: the production snapshot directory, checkpoints file and 64 MiB cap are committed"
else
  fail "p2: production bindings" "the committed snapshot directory, checkpoints file or cap differs"
fi

# Source path and name.
mkdir -m 0700 "${fx_root}/other"
cp -p -- "$fx_snap" "${fx_root}/other/${p2_name}"
expect "p2: a copy outside the snapshot directory is refused" 1 "must be directly in ${fx_snapdir}" -- \
  p2_encrypt -- --source "${fx_root}/other/${p2_name}" --out "${fx_out}/s.age"
for alias in "${fx_snapdir}/./${p2_name}" "${fx_snapdir}//${p2_name}" "${fx_root}/state/../snapshots/${p2_name}" "${fx_snap}/"; do
  expect "p2: the alias ${alias#"$fx_root"} is refused" 1 "must be an absolute, normalized path" -- \
    p2_encrypt -- --source "$alias" --out "${fx_out}/s.age"
done
rel_p2() { (cd "$fx_snapdir" && p2_encrypt -- --source "$p2_name" --out "${fx_out}/s.age"); }
expect "p2: a relative path is refused" 1 "must be an absolute, normalized path" -- rel_p2
for other_name in stage3-p1-pre-rotate-20261029t135952z-k3s01-1793282417 stage3-p2-post-encryption-20261029t144551z-k3s02-1793285175 \
  stage3-p2-post-encryption-20261029T144551Z-k3s01-1793285175 "${p2_name}.bak" etcd-snapshot-k3s01-1793285175; do
  cp -p -- "$fx_snap" "${fx_snapdir}/${other_name}"
  expect "p2: a snapshot named ${other_name} is refused" 1 "is not named as a p2 post-encryption snapshot" -- \
    p2_encrypt -- --source "${fx_snapdir}/${other_name}" --out "${fx_out}/s.age"
  rm -f -- "${fx_snapdir}/${other_name}"
done
ln -s "$fx_snapdir" "${fx_root}/snap-link"
expect "p2: a symbolic link to the snapshot directory is refused" 1 "a directory in the source path is a symbolic link: ${fx_root}/snap-link" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR="${fx_root}/snap-link" -- --source "${fx_root}/snap-link/${p2_name}" --out "${fx_out}/s.age"
ln -s "$fx_root" "${tmp}/g-root-link"
expect "p2: a symbolic link to an ancestor directory is refused" 1 "a directory in the source path is a symbolic link: ${tmp}/g-root-link" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR="${tmp}/g-root-link/snapshots" -- --source "${tmp}/g-root-link/snapshots/${p2_name}" --out "${fx_out}/s.age"
expect "p2: a missing snapshot directory is refused" 1 "snapshot directory does not exist: ${fx_root}/absent" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR="${fx_root}/absent" -- --source "${fx_root}/absent/${p2_name}" --out "${fx_out}/s.age"
expect "p2: a snapshot directory not owned by root:root is refused" 1 "snapshot directory is not owned by root:root (owner ${me})" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_PARENT_OWNER=0:0 -- --source "$fx_snap" --out "${fx_out}/s.age"
for mode in 0770 0702 1777; do
  chmod "$mode" "$fx_snapdir"
  expect "p2: a mode ${mode} snapshot directory is refused" 1 "snapshot directory is writable by group or others (mode ${mode#0})" -- \
    p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
done
chmod 0700 "$fx_snapdir"
for bad_override in relative/snapshots "${fx_root}/./snapshots" "${fx_snapdir}/"; do
  expect "p2: a non-normalized snapshot-directory override is refused" 1 "RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR must be an absolute, normalized path" -- \
    p2_encrypt RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR="$bad_override" -- --source "$fx_snap" --out "${fx_out}/s.age"
done

# The file itself.
p2_alt="${fx_snapdir}/stage3-p2-post-encryption-20261029t144552z-k3s01-1793285176"
ln -s "$fx_snap" "$p2_alt"
expect "p2: a symbolic link with a p2 name is refused" 1 "source is a symbolic link" -- \
  p2_encrypt -- --source "$p2_alt" --out "${fx_out}/s.age"
rm -f -- "$p2_alt"
mkfifo -m 0600 "$p2_alt"
expect "p2: a FIFO with a p2 name is refused" 1 "source is not a regular file" -- \
  p2_encrypt -- --source "$p2_alt" --out "${fx_out}/s.age"
rm -f -- "$p2_alt"
install -m 0600 /dev/null "$p2_alt"
expect "p2: an empty file with a p2 name is refused" 1 "source is empty" -- \
  p2_encrypt -- --source "$p2_alt" --out "${fx_out}/s.age"
rm -f -- "$p2_alt"
ln -- "$fx_snap" "${fx_root}/other/hard-link"
expect "p2: a snapshot with another hard link is refused" 1 "source has other hard links" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
rm -f -- "${fx_root}/other/hard-link"
chmod 0400 "$fx_snap"
expect "p2: a mode 0400 snapshot is refused" 1 "source must be mode 600 (mode 400)" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
for mode in 0640 0604 0660; do
  chmod "$mode" "$fx_snap"
  expect "p2: a mode ${mode} snapshot is refused" 1 "accessible to group or others (mode ${mode#0})" -- \
    p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
done
chmod 0600 "$fx_snap"
for source_owner in 0:0 "$other_user" "$other_group"; do
  expect "p2: a snapshot not owned by the required ${source_owner} is refused" 1 "source is not owned by root:root (owner ${me})" -- \
    p2_encrypt RECOVERY_MATERIAL_TEST_SOURCE_OWNER="$source_owner" -- --source "$fx_snap" --out "${fx_out}/s.age"
done
source_owner=""

# The 64 MiB cap, before any digest is computed.
p2_fixture
truncate -s $(( 64 * 1024 * 1024 + 1 )) "$fx_snap"
expect "p2: a snapshot over the 64 MiB cap is refused" 1 "source exceeds the 64 MiB cap" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
truncate -s $(( 64 * 1024 * 1024 )) "$fx_snap"
expect "p2: a snapshot of exactly 64 MiB passes the cap (and reaches the checkpoint check)" 1 "source size differs from its checkpoint record" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"

# The checkpoint record.
p2_fixture
expect "p2: a missing checkpoints file is refused" 1 "checkpoints file does not exist or is not a regular file" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_CHECKPOINTS="${fx_root}/state/absent" -- --source "$fx_snap" --out "${fx_out}/s.age"
ln -s "$fx_ckpt" "${fx_root}/state/link"
expect "p2: a symbolic-link checkpoints file is refused" 1 "checkpoints file is a symbolic link" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_CHECKPOINTS="${fx_root}/state/link" -- --source "$fx_snap" --out "${fx_out}/s.age"
ln -- "$fx_ckpt" "${fx_root}/other-ckpt-link"
expect "p2: a checkpoints file with another hard link is refused" 1 "checkpoints file has other hard links" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
rm -f -- "${fx_root}/other-ckpt-link"
for mode in 0640 0604; do
  chmod "$mode" "$fx_ckpt"
  expect "p2: a mode ${mode} checkpoints file is refused" 1 "checkpoints file is accessible to group or others (mode ${mode#0})" -- \
    p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
done
chmod 0600 "$fx_ckpt"
chmod 0770 "${fx_root}/state"
expect "p2: a group-writable checkpoint directory is refused" 1 "checkpoint directory is writable by group or others (mode 770)" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
chmod 0700 "${fx_root}/state"
expect "p2: a non-normalized checkpoints override is refused" 1 "RECOVERY_MATERIAL_TEST_CHECKPOINTS must be an absolute, normalized path" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_CHECKPOINTS="${fx_root}/state/../state/checkpoints" -- --source "$fx_snap" --out "${fx_out}/s.age"
p2_record_case() {
  local label="$1" message="$2"
  shift 2
  p2_checkpoints "$@"
  expect "p2: checkpoint record: ${label} is refused" 1 "$message" -- p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"
  p2_checkpoints "$fx_record"
}
other_p2="stage3-p2-post-encryption-20261030t000000z-k3s01-1793318400"
p2_record_case "no record" "exactly one record for the source (found 0)"
p2_record_case "two records" "exactly one record for the source (found 2)" "$fx_record" "$fx_record"
p2_record_case "a second p2 record" "exactly one ${p2_label} record (found 2)" "$fx_record" \
  "1793318400 ${p2_label} ${other_p2} ${fx_size} ${fake_sum} token=present"
p2_record_case "another label" "malformed or is not the ${p2_label} record" \
  "${fx_mtime} p1-pre-rotate ${p2_name} ${fx_size} ${fx_sha} token=present" \
  "1793318400 ${p2_label} ${other_p2} ${fx_size} ${fake_sum} token=present"
p2_record_case "no token field" "malformed or is not the ${p2_label} record" "${fx_mtime} ${p2_label} ${p2_name} ${fx_size} ${fx_sha}"
p2_record_case "an extra field" "malformed or is not the ${p2_label} record" "${fx_record} extra"
p2_record_case "an uppercase SHA-256" "malformed or is not the ${p2_label} record" "${fx_mtime} ${p2_label} ${p2_name} ${fx_size} ${fx_sha^^} token=present"
p2_record_case "a CRLF line" "malformed or is not the ${p2_label} record" "${fx_record}"$'\r'
p2_record_case "another size" "source size differs from its checkpoint record" "${fx_mtime} ${p2_label} ${p2_name} $(( fx_size + 1 )) ${fx_sha} token=present"
p2_record_case "another time" "source modification time differs from its checkpoint record" "$(( fx_mtime - 1 )) ${p2_label} ${p2_name} ${fx_size} ${fx_sha} token=present"
p2_record_case "another SHA-256" "source SHA-256 differs from its checkpoint record" "${fx_mtime} ${p2_label} ${p2_name} ${fx_size} ${fake_sum} token=present"
# Source substitution: another file under the p2 name, with the recorded size and time.
[[ -d "${fx_root}/other" ]] || mkdir -m 0700 "${fx_root}/other"
head -c "$fx_size" /dev/urandom >"${fx_root}/other/substitute"
cat -- "${fx_root}/other/substitute" >"$fx_snap"
touch -d "@${fx_mtime}" -- "$fx_snap"
expect "p2: a substituted snapshot with the recorded name, size and time is refused" 1 "source SHA-256 differs from its checkpoint record" -- \
  p2_encrypt -- --source "$fx_snap" --out "${fx_out}/s.age"

# sudo from the operator's own account.
p2_fixture
for sudo_case in "RECOVERY_MATERIAL_TEST_SUDO_USER=" "RECOVERY_MATERIAL_TEST_SUDO_USER=root" \
  "RECOVERY_MATERIAL_TEST_SUDO_UID=0" "RECOVERY_MATERIAL_TEST_SUDO_UID=" "RECOVERY_MATERIAL_TEST_SUDO_UID=x1"; do
  expect "p2: encrypt without a non-root sudo operator (${sudo_case}) is refused" 1 "must be encrypted through sudo from the operator's own (non-root) account" -- \
    p2_encrypt "$sudo_case" -- --source "$fx_snap" --out "${fx_out}/s.age"
done
expect "p2: an output directory not owned by the sudo operator is refused" 1 "output directory is not owned by the operator" -- \
  p2_encrypt RECOVERY_MATERIAL_TEST_SUDO_UID="$(( me_uid + 1 ))" -- --source "$fx_snap" --out "${fx_out}/s.age"
for name in RECOVERY_MATERIAL_TEST_SNAPSHOT_DIR RECOVERY_MATERIAL_TEST_CHECKPOINTS RECOVERY_MATERIAL_TEST_SUDO_USER \
  RECOVERY_MATERIAL_TEST_SUDO_UID RECOVERY_MATERIAL_TEST_MEMINFO; do
  expect "p2: ${name} outside test mode is refused" 1 "${name} is test-only and is refused outside test mode" -- \
    env -u RECOVERY_MATERIAL_TEST -u RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE PATH="$stub_path" "${name}=${fx_snapdir}" \
    bash "$helper" encrypt --item "$p2_item" --source "$fx_snap" --out "${fx_out}/s.age"
done
if empty_dir "$fx_out"; then pass "p2: refused encryptions write no ciphertext"; else fail "p2: refused encryptions" "a ciphertext was written"; fi

# verify, before anything is decrypted (stub age).
one_sum="$(sha256sum -- "${tmp}/one-x25519.age" | cut -d' ' -f1)"
expect "p2: verify without --ciphertext-sha256 is refused" 1 "verify needs --ciphertext-sha256" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --source "$fx_snap"
expect "p2: verify with a malformed --ciphertext-sha256 is refused" 1 "--ciphertext-sha256 must be 64 hexadecimal characters" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "${one_sum:0:63}" --source "$fx_snap"
expect "p2: verify of a ciphertext with another SHA-256 is refused" 1 "does not have the expected SHA-256 (incomplete or different transfer); nothing was decrypted" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$fake_sum" --source "$fx_snap"
expect "p2: verify reaches decryption with the expected SHA-256 (stub age fails)" 1 "result: ERROR" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"
p2_checkpoints "${fx_mtime} ${p2_label} ${p2_name} ${fx_size} ${fake_sum} token=present"
expect "p2: verify refuses a snapshot that is not the checkpointed one" 1 "source SHA-256 differs from its checkpoint record" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"
p2_checkpoints "$fx_record"
chmod 0400 "$fx_snap"
expect "p2: verify applies the snapshot checks (mode 0400 refused)" 1 "source must be mode 600 (mode 400)" -- \
  p2_verify -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"
chmod 0600 "$fx_snap"
meminfo() { printf 'MemTotal:       8131788 kB\nMemAvailable: %8s kB\n' "$1" >"${tmp}/meminfo"; }
meminfo 163839
expect "p2: verify refuses when MemAvailable is below twice the 80 MiB tmpfs" 1 "not enough available memory for the 80 MiB private tmpfs" -- \
  p2_verify RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/meminfo" -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"
meminfo 163840
expect "p2: verify accepts exactly twice the tmpfs size (reaches decryption)" 1 "result: ERROR" -- \
  p2_verify RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/meminfo" -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"
meminfo 100000
expect "p2: the small items keep the 4 MiB tmpfs (100000 kB is enough)" 1 "result: ERROR" -- \
  run_test_mode env PATH="$stub_path" RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/meminfo" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" \
  RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" bash "$helper" verify --item k3s-server-token --ciphertext "${tmp}/one-x25519.age" --source "$source_file"
expect "p2: an unreadable MemAvailable is refused" 1 "could not read MemAvailable" -- \
  p2_verify RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/absent-meminfo" -- --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap"

# TERM during the decryption of a snapshot ciphertext.
g_term="$(fresh_dir)"
g_pidfile="${tmp}/stub-age-p2.pid"
set +e
p2 STUB_AGE_SLEEP_PIDFILE="$g_pidfile" RECOVERY_MATERIAL_TEST_IDENTITY="${tmp}/plain-identity.txt" RECOVERY_MATERIAL_TEST_TMPDIR="$g_term" -- \
  verify --item "$p2_item" --ciphertext "${tmp}/one-x25519.age" --ciphertext-sha256 "$one_sum" --source "$fx_snap" >"${tmp}/g-term.out" 2>&1 &
g_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$g_pidfile" ]] && break
  sleep 0.1
done
g_seen="$(find "$g_term" -mindepth 1 -maxdepth 1 -printf '%f ')"
g_bash="$(pgrep -P "$g_pid" -f recovery-material.sh || echo "$g_pid")"
kill -TERM "$g_bash" 2>/dev/null
kill -TERM "$(cat "$g_pidfile" 2>/dev/null)" 2>/dev/null
wait "$g_pid"
g_rc=$?
set -e
if [[ "$g_seen" == "plain " && "$g_rc" -eq 143 ]] && empty_dir "$g_term" && ! leaked "${tmp}/g-term.out"; then
  pass "p2: TERM during decryption removes the plaintext and exits 143"
else
  fail "p2: TERM during decryption" "exit ${g_rc}; seen: ${g_seen}; left: $(find "$g_term" -mindepth 1 -maxdepth 1 -printf '%f ')"
fi

# Round trips, ownership transitions and substitution during encryption (real age).
if (( real_age_ok )); then
  p2_age_path="$PATH"
  real_age="$(command -v age)"
  key_vars=(RECOVERY_MATERIAL_TEST_RECIPIENT="${key_dir}/recipient" RECOVERY_MATERIAL_TEST_IDENTITY="${key_dir}/identity")
  p2_fixture
  expect "p2: the checkpointed snapshot encrypts" ok "the only ${p2_label} checkpoint record with matching name, size, time and SHA-256" -- \
    p2_encrypt "${key_vars[@]}" -- --source "$fx_snap" --out "${fx_out}/stage3-p2-snapshot.age"
  g_ct="${fx_out}/stage3-p2-snapshot.age"
  g_ct_sha="$(sed -n 's/^ciphertext sha256: //p' "${tmp}/out")"
  if [[ -f "$g_ct" && "$(stat -c '%u %a %h' -- "$g_ct")" == "${me_uid} 600 1" && "$(tail -n 1 "$runuser_log")" == "$me_user" \
    && "$g_ct_sha" == "$(sha256sum -- "$g_ct" | cut -d' ' -f1)" && "$(grep -ac '^-> X25519 ' "$g_ct")" == "1" ]] \
    && ! grep -aqF "$sentinel" "$g_ct"; then
    pass "p2: the ciphertext is created through runuser by the operator: mode 600, one link, printed SHA-256, no plaintext"
  else
    fail "p2: ciphertext ownership and properties" "owner, mode, links, runuser, SHA-256 or header differs"
  fi
  if ! grep -qF "$fx_size" "${tmp}/out"; then pass "p2: the snapshot size is not printed"; else fail "p2: snapshot size" "printed"; fi

  # A broken ownership transition: the created file is not mode 600, or has another link.
  for chmod_mode in 0644 0640 0400; do
    expect "p2: a ciphertext left mode ${chmod_mode} is removed and refused" 1 "is not a regular, singly linked, mode 600 file owned by the operator; it was removed" -- \
      p2_encrypt "${key_vars[@]}" STUB_RUNUSER_CHMOD="$chmod_mode" -- --source "$fx_snap" --out "${fx_out}/bad-${chmod_mode}.age"
    if [[ ! -e "${fx_out}/bad-${chmod_mode}.age" ]]; then pass "p2: the mode ${chmod_mode} ciphertext was removed"; else fail "p2: mode ${chmod_mode} ciphertext" "left behind"; fi
  done
  expect "p2: a ciphertext with another hard link is removed and refused" 1 "it was removed" -- \
    p2_encrypt "${key_vars[@]}" STUB_RUNUSER_LINK="${fx_root}/other-link.age" -- --source "$fx_snap" --out "${fx_out}/linked.age"
  if [[ ! -e "${fx_out}/linked.age" && -f "${fx_root}/other-link.age" ]]; then
    pass "p2: the linked ciphertext's own name was removed (the planted link is outside the run)"
  else
    fail "p2: linked ciphertext" "the run's name was left, or the planted link is missing"
  fi
  rm -f -- "${fx_root}/other-link.age"

  # Substitution during encryption: an age wrapper changes the source after reading it.
  age_wrap_dir="${tmp}/age-wrap"
  mkdir -p "$age_wrap_dir"
  cat >"${age_wrap_dir}/age" <<EOF
#!/usr/bin/env bash
"${real_age}" "\$@"
rc=\$?
if [[ "\${1:-}" != "--version" && -n "\${WRAP_AGE_TOUCH:-}" ]]; then
  touch -d @1 -- "\$WRAP_AGE_TOUCH"
fi
if [[ "\${1:-}" != "--version" && -n "\${WRAP_AGE_REWRITE:-}" ]]; then
  m="\$(stat -c %Y -- "\$WRAP_AGE_REWRITE")"
  head -c "\$(stat -c %s -- "\$WRAP_AGE_REWRITE")" /dev/urandom >"\${WRAP_AGE_REWRITE}.new"
  cat -- "\${WRAP_AGE_REWRITE}.new" >"\$WRAP_AGE_REWRITE"
  rm -f -- "\${WRAP_AGE_REWRITE}.new"
  touch -d "@\${m}" -- "\$WRAP_AGE_REWRITE"
fi
exit "\$rc"
EOF
  chmod 0755 "${age_wrap_dir}/age"
  for wrap in WRAP_AGE_TOUCH WRAP_AGE_REWRITE; do
    p2_fixture
    p2_age_path="${age_wrap_dir}:${PATH}" expect "p2: a source changed during encryption (${wrap}) is refused" 1 \
      "the source changed during encryption; the ciphertext was removed" -- \
      p2_encrypt "${key_vars[@]}" "${wrap}=${fx_snap}" -- --source "$fx_snap" --out "${fx_out}/changed.age"
    if empty_dir "$fx_out"; then pass "p2: the ciphertext of a changed source was removed (${wrap})"; else fail "p2: changed source" "ciphertext left"; fi
  done

  # verify: MATCH, DIFFER, ERROR and an interrupted transfer, each leaving nothing behind.
  p2_fixture
  p2_encrypt "${key_vars[@]}" -- --source "$fx_snap" --out "${fx_out}/stage3-p2-snapshot.age" >"${tmp}/out" 2>&1
  g_ct="${fx_out}/stage3-p2-snapshot.age"
  g_ct_sha="$(sha256sum -- "$g_ct" | cut -d' ' -f1)"
  g_match="$(fresh_dir)"
  expect "p2: verify reports MATCH in an 80 MiB tmpfs" ok "private tmpfs: 80 MiB" -- \
    p2 "${key_vars[@]}" RECOVERY_MATERIAL_TEST_TMPDIR="$g_match" -- verify --item "$p2_item" --ciphertext "$g_ct" \
    --ciphertext-sha256 "$g_ct_sha" --source "$fx_snap"
  if grep -qF "result: MATCH" "${tmp}/out" && empty_dir "$g_match"; then pass "p2: MATCH leaves no plaintext behind"; else fail "p2: MATCH" "result or cleanup"; fi
  head -c "$fx_size" /dev/urandom >"${tmp}/g-other-plain"
  age -R "${key_dir}/recipient" -o "${tmp}/g-other.age" -- "${tmp}/g-other-plain"
  g_differ="$(fresh_dir)"
  expect "p2: verify reports DIFFER for another snapshot's ciphertext" 1 "result: DIFFER" -- \
    p2 "${key_vars[@]}" RECOVERY_MATERIAL_TEST_TMPDIR="$g_differ" -- verify --item "$p2_item" --ciphertext "${tmp}/g-other.age" \
    --ciphertext-sha256 "$(sha256sum -- "${tmp}/g-other.age" | cut -d' ' -f1)" --source "$fx_snap"
  if empty_dir "$g_differ"; then pass "p2: DIFFER leaves no plaintext behind"; else fail "p2: DIFFER cleanup" "tmpdir not empty"; fi
  age -R "${key_dir}/other-recipient" -o "${tmp}/g-wrong.age" -- "$fx_snap"
  g_error="$(fresh_dir)"
  expect "p2: verify reports ERROR for another recipient's ciphertext" 1 "result: ERROR" -- \
    p2 "${key_vars[@]}" RECOVERY_MATERIAL_TEST_TMPDIR="$g_error" -- verify --item "$p2_item" --ciphertext "${tmp}/g-wrong.age" \
    --ciphertext-sha256 "$(sha256sum -- "${tmp}/g-wrong.age" | cut -d' ' -f1)" --source "$fx_snap"
  if empty_dir "$g_error"; then pass "p2: ERROR leaves no plaintext behind"; else fail "p2: ERROR cleanup" "tmpdir not empty"; fi
  head -c "$(( $(stat -c %s -- "$g_ct") / 2 ))" -- "$g_ct" >"${tmp}/g-partial.age"
  g_partial="$(fresh_dir)"
  expect "p2: an interrupted transfer to k3s01 is refused before decryption" 1 "nothing was decrypted" -- \
    p2 "${key_vars[@]}" RECOVERY_MATERIAL_TEST_TMPDIR="$g_partial" -- verify --item "$p2_item" --ciphertext "${tmp}/g-partial.age" \
    --ciphertext-sha256 "$g_ct_sha" --source "$fx_snap"
  if empty_dir "$g_partial"; then pass "p2: the refused transfer decrypted nothing"; else fail "p2: refused transfer" "tmpdir not empty"; fi
  expect "p2: a small item still uses the 4 MiB tmpfs" ok "private tmpfs: 4 MiB" -- \
    round env RECOVERY_MATERIAL_TEST_TMPDIR="$(fresh_dir)" bash "$helper" verify --item k3s-server-token \
    --ciphertext "${out_dir}/token.age" --source "$source_file"

  # The operator-owned ciphertext is removable by the scoped cleanup, as on k3s01.
  g_parent="$(fresh_dir)"
  g_host="${g_parent}/out"
  run_helper "$helper" start-run --dir "$g_host" >/dev/null
  p2_encrypt "${key_vars[@]}" -- --source "$fx_snap" --out "${g_host}/stage3-p2-snapshot.age" >/dev/null 2>&1
  cp -- "$g_ct" "${g_host}/stage3-p2-snapshot.downloaded.age"
  write_header "${g_host}/identity-archive.age" scrypt
  expect "p2: the per-host cleanup removes the operator-owned run files" ok "run directory: absent" -- \
    run_helper "$helper" cleanup --dir "$g_host" --remove stage3-p2-snapshot.age \
    --remove stage3-p2-snapshot.downloaded.age --remove identity-archive.age
  if [[ ! -e "$g_host" && -f "$fx_snap" && "$(sha256sum -- "$fx_snap" | cut -d' ' -f1)" == "$fx_sha" ]]; then
    pass "p2: the cleanup left the snapshot unchanged"
  else
    fail "p2: cleanup" "run directory left, or snapshot changed"
  fi
  unset p2_age_path
elif [[ "${RECOVERY_MATERIAL_REQUIRE_AGE:-}" == "1" ]]; then
  fail "group G round trips" "age and age-keygen v1.3.2 are required (RECOVERY_MATERIAL_REQUIRE_AGE=1)"
else
  skipped=$((skipped + 1))
  echo "skip group G round trips: age and age-keygen v1.3.2 are not on PATH"
fi

# S3: receipts, the expected ciphertext SHA-256, collisions and explicit new versions.
g_s3_tmp="$(fresh_dir)"
g_s3() { s3 env TMPDIR="$g_s3_tmp" "$@"; }
g_date=2026-10-29
g_receipts="$(fresh_dir)"
g_object="${store}/recovery_stage3-p2-snapshot_${g_date}.age"
write_header "${tmp}/g-upload.age" X25519
head -c 4096 /dev/urandom >>"${tmp}/g-upload.age"
g_up_sha="$(sha256sum -- "${tmp}/g-upload.age" | cut -d' ' -f1)"
EXTRA_FORBIDDEN=stub-version-
expect "p2 S3: upload without --receipt is refused" 1 "upload needs --receipt" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha"
expect "p2 S3: upload without --ciphertext-sha256 is refused" 1 "upload needs --ciphertext-sha256" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --receipt "${g_receipts}/a"
expect "p2 S3: a malformed --ciphertext-sha256 is refused" 1 "--ciphertext-sha256 must be 64 hexadecimal characters" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 x --receipt "${g_receipts}/a"
expect "p2 S3: a file with another SHA-256 is refused" 1 "nothing was uploaded" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$fake_sum" --receipt "${g_receipts}/a"
head -c "$(( $(stat -c %s -- "${tmp}/g-upload.age") / 2 ))" -- "${tmp}/g-upload.age" >"${tmp}/g-partial-upload.age"
expect "p2 S3: an interrupted transfer to the workstation is refused" 1 "does not have the expected SHA-256 (incomplete or different transfer)" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-partial-upload.age" --ciphertext-sha256 "$g_up_sha" --receipt "${g_receipts}/a"
write_header "${tmp}/g-big.age" X25519
truncate -s $(( 65 * 1024 * 1024 + 1 )) "${tmp}/g-big.age"
expect "p2 S3: a ciphertext over 65 MiB is refused" 1 "ciphertext exceeds 65 MiB" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-big.age" \
  --ciphertext-sha256 "$(sha256sum -- "${tmp}/g-big.age" | cut -d' ' -f1)" --receipt "${g_receipts}/a"
rm -f -- "${tmp}/g-big.age"
if [[ ! -e "$g_object" && -z "$(ls -A -- "$g_receipts")" ]]; then pass "p2 S3: refused uploads send nothing and write no receipt"; else fail "p2 S3: refused uploads" "object or receipt written"; fi
expect "p2 S3: upload writes a private receipt" ok "version receipt: ${g_receipts}/a" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" --receipt "${g_receipts}/a"
if grep -qF "key: recovery/stage3-p2-snapshot/${g_date}.age" "${tmp}/out" && [[ "$(stat -c '%a' "${g_receipts}/a")" == "600" ]] \
  && [[ "$(cat "${g_receipts}/a")" == "key: recovery/stage3-p2-snapshot/${g_date}.age"$'\n'"version id: stub-version-1" ]]; then
  pass "p2 S3: the receipt holds the stage3-p2-snapshot key and version, mode 600"
else
  fail "p2 S3: receipt" "key, mode or contents differ"
fi
expect "p2 S3: a second upload to the same key is refused" 1 "already exists; pass --new-version with --replaces-sha256" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" --receipt "${g_receipts}/b"
expect "p2 S3: --new-version without --replaces-sha256 is refused" 1 "--new-version needs --replaces-sha256" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" --receipt "${g_receipts}/b" --new-version
expect "p2 S3: --new-version without --receipt is refused" 1 "--new-version needs --receipt" -- \
  g_s3 bash "$s3_helper" upload --item grafana-admin --date "$g_date" --file "${tmp}/g-upload.age" --new-version --replaces-sha256 "$g_up_sha"
expect "p2 S3: --replaces-sha256 without --new-version is refused" 1 "--replaces-sha256 is only valid with --new-version" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date 2026-10-31 --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" \
  --receipt "${g_receipts}/b" --replaces-sha256 "$g_up_sha"
expect "p2 S3: --new-version replacing another SHA-256 is refused" 1 "does not have the SHA-256 given with --replaces-sha256; nothing was uploaded" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" \
  --receipt "${g_receipts}/b" --new-version --replaces-sha256 "$fake_sum"
expect "p2 S3: --new-version when S3 has no stored checksum is refused" 1 "has no stored SHA-256 checksum" -- \
  g_s3 env FAKE_AWS_NO_CHECKSUM=1 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" \
  --ciphertext-sha256 "$g_up_sha" --receipt "${g_receipts}/b" --new-version --replaces-sha256 "$g_up_sha"
expect "p2 S3: --new-version for a key that does not exist is refused" 1 "does not exist; --new-version only adds a version to an existing key" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date 2026-10-30 --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" \
  --receipt "${g_receipts}/b" --new-version --replaces-sha256 "$g_up_sha"
if [[ -z "$(find "$store" -maxdepth 1 -name 'recovery_stage3-p2-snapshot_*.stub-version-*' -print -quit)" && ! -e "${g_receipts}/b" ]]; then
  pass "p2 S3: refused new versions add no version and write no receipt"
else
  fail "p2 S3: refused new versions" "a version or receipt was written"
fi
# After a lost receipt: the same ciphertext again, as an explicit new version.
expect "p2 S3: an explicit new version over the recorded ciphertext is accepted" ok "version receipt: ${g_receipts}/b" -- \
  g_s3 bash "$s3_helper" upload --item "$p2_item" --date "$g_date" --file "${tmp}/g-upload.age" --ciphertext-sha256 "$g_up_sha" \
  --receipt "${g_receipts}/b" --new-version --replaces-sha256 "$g_up_sha"
if [[ "$(sed -n 's/^version id: //p' "${g_receipts}/b")" == "stub-version-2" ]]; then pass "p2 S3: the new version is pinned in its own receipt"; else fail "p2 S3: new version" "receipt version differs"; fi
expect "p2 S3: download by --version-id is refused" 1 "download needs --receipt" -- \
  g_s3 bash "$s3_helper" download --item "$p2_item" --date "$g_date" --version-id stub-version-1 \
  --out "${tmp}/g-d0.age" --compare-with "${tmp}/g-upload.age"
for receipt_name in a b; do
  expect "p2 S3: download by receipt ${receipt_name} reports MATCH" ok "result: MATCH" -- \
    g_s3 bash "$s3_helper" download --item "$p2_item" --date "$g_date" --receipt "${g_receipts}/${receipt_name}" \
    --out "${tmp}/g-d-${receipt_name}.age" --compare-with "${tmp}/g-upload.age"
done
EXTRA_FORBIDDEN=""

# A same-date inventory update, as an explicit new version on top of the exact previous one.
write_header "${tmp}/g-inv-a.age" X25519
printf 'inventory-a' >>"${tmp}/g-inv-a.age"
write_header "${tmp}/g-inv-b.age" X25519
printf 'inventory-b' >>"${tmp}/g-inv-b.age"
g_inv_a_sha="$(sha256sum -- "${tmp}/g-inv-a.age" | cut -d' ' -f1)"
g_inv_b_sha="$(sha256sum -- "${tmp}/g-inv-b.age" | cut -d' ' -f1)"
expect "inventory: the first inventory of the day uploads" ok "version id: stub-version-1" -- \
  g_s3 bash "$s3_helper" upload --item recovery-inventory --date "$g_date" --file "${tmp}/g-inv-a.age"
expect "inventory: a same-date update without --new-version is refused" 1 "already exists" -- \
  g_s3 bash "$s3_helper" upload --item recovery-inventory --date "$g_date" --file "${tmp}/g-inv-b.age" --receipt "${g_receipts}/inv"
expect "inventory: a same-date update replacing the wrong version is refused" 1 "does not have the SHA-256 given with --replaces-sha256" -- \
  g_s3 bash "$s3_helper" upload --item recovery-inventory --date "$g_date" --file "${tmp}/g-inv-b.age" --receipt "${g_receipts}/inv" \
  --new-version --replaces-sha256 "$g_inv_b_sha"
EXTRA_FORBIDDEN=stub-version-2
expect "inventory: a same-date update is added as an explicit, receipted new version" ok "version receipt: ${g_receipts}/inv" -- \
  g_s3 bash "$s3_helper" upload --item recovery-inventory --date "$g_date" --file "${tmp}/g-inv-b.age" --receipt "${g_receipts}/inv" \
  --new-version --replaces-sha256 "$g_inv_a_sha"
expect "inventory: the new version downloads by its receipt" ok "result: MATCH" -- \
  g_s3 bash "$s3_helper" download --item recovery-inventory --date "$g_date" --receipt "${g_receipts}/inv" \
  --out "${tmp}/g-inv-b.downloaded.age" --compare-with "${tmp}/g-inv-b.age"
EXTRA_FORBIDDEN=""
expect "inventory: the previous same-date version is still downloadable" ok "result: MATCH" -- \
  g_s3 bash "$s3_helper" download --item recovery-inventory --date "$g_date" --version-id stub-version-1 \
  --out "${tmp}/g-inv-a.downloaded.age" --compare-with "${tmp}/g-inv-a.age"
expect "inventory: a stale update on top of the replaced version is refused" 1 "does not have the SHA-256 given with --replaces-sha256" -- \
  g_s3 bash "$s3_helper" upload --item recovery-inventory --date "$g_date" --file "${tmp}/g-inv-b.age" --receipt "${g_receipts}/inv2" \
  --new-version --replaces-sha256 "$g_inv_a_sha"
if empty_dir "$g_s3_tmp"; then pass "p2 S3: work directories removed after every case"; else fail "p2 S3: cleanup" "work directory left behind"; fi

# The scoped cleanup with the snapshot's run files (no test mode).
g_ws_parent="$(fresh_dir)"
g_kept="${g_ws_parent}/recovery-inventory.age"
write_header "$g_kept" X25519
g_ws="${g_ws_parent}/run-2026-10-30"
run_helper "$helper" start-run --dir "$g_ws" >/dev/null
head -c 60 -- "${tmp}/g-upload.age" >"${g_ws}/stage3-p2-snapshot.age"
for name in stage3-p2-snapshot.downloaded.age recovery-inventory.age recovery-inventory.downloaded.age; do write_header "${g_ws}/${name}" X25519; done
touch "${g_ws}/stage3-p2-snapshot.age.part"
expect "p2 cleanup: an unexpected partial-transfer name refuses the whole cleanup" 1 "unexpected entry in the run directory; nothing was removed" -- \
  run_helper "$helper" cleanup --dir "$g_ws" --remove stage3-p2-snapshot.age --remove stage3-p2-snapshot.downloaded.age \
  --remove recovery-inventory.age --remove recovery-inventory.downloaded.age --keep "$g_kept"
expect "p2 cleanup: a receipt name is not a run file" 1 "not a run file name" -- \
  run_helper "$helper" cleanup --dir "$g_ws" --remove stage3-p2-snapshot.receipt
if [[ "$(find "$g_ws" -mindepth 1 -maxdepth 1 | wc -l)" -eq 6 ]]; then pass "p2 cleanup: the refusals removed nothing"; else fail "p2 cleanup refusals" "files removed"; fi
rm -f -- "${g_ws}/stage3-p2-snapshot.age.part"
expect "p2 cleanup: a truncated transfer and the run's other files are removed; the earlier inventory is kept" ok "retained unchanged: ${g_kept}" -- \
  run_helper "$helper" cleanup --dir "$g_ws" --remove stage3-p2-snapshot.age --remove stage3-p2-snapshot.downloaded.age \
  --remove recovery-inventory.age --remove recovery-inventory.downloaded.age --keep "$g_kept"
if [[ ! -e "$g_ws" && -f "$g_kept" ]]; then pass "p2 cleanup: run directory absent, earlier inventory present"; else fail "p2 cleanup" "run directory left or earlier inventory missing"; fi

# Mutants: each guard disabled in a copy of a helper must let its scenario through.
g_mutant="${mutant_dir}/recovery-material.sh"
g_s3_mutant="${mutant_dir}/recovery-material-s3.sh"
g_mutant_case() {
  local label="$1" source="$2" expression="$3" scenario="$4" target
  target="$g_mutant"
  [[ "$source" == "$s3_helper" ]] && target="$g_s3_mutant"
  sed "$expression" "$source" >"$target"
  if cmp -s -- "$source" "$target"; then
    fail "p2 mutant: ${label}" "mutation anchor not found"
  elif ! "$scenario" "$source"; then
    fail "p2 mutant: ${label}" "the scenario fails against the real helper"
  elif "$scenario" "$target"; then
    fail "p2 mutant: ${label}" "the scenario passed with the guard disabled"
  else
    pass "p2 mutant: ${label}: killed by ${scenario#sc_}"
  fi
}
sc_encrypt_refused() { # HELPER MESSAGE [NAME=VALUE...]
  local helper_path="$1" message="$2"
  shift 2
  p2_helper="$helper_path" refused "$message" -- p2_encrypt "$@" -- --source "$fx_snap" --out "${fx_out}/m.age"
}
sc_substituted() { p2_fixture; head -c "$fx_size" /dev/urandom >"${fx_root}/sub"; cat -- "${fx_root}/sub" >"$fx_snap"; touch -d "@${fx_mtime}" -- "$fx_snap"; sc_encrypt_refused "$1" "SHA-256 differs from its checkpoint record"; }
sc_size() { p2_fixture; p2_checkpoints "${fx_mtime} ${p2_label} ${p2_name} $(( fx_size + 1 )) ${fx_sha} token=present"; sc_encrypt_refused "$1" "source size differs"; }
sc_mtime() { p2_fixture; p2_checkpoints "$(( fx_mtime + 1 )) ${p2_label} ${p2_name} ${fx_size} ${fx_sha} token=present"; sc_encrypt_refused "$1" "modification time differs"; }
sc_one_record() { p2_fixture; p2_checkpoints "$fx_record" "$fx_record"; sc_encrypt_refused "$1" "exactly one record for the source"; }
sc_one_label() { p2_fixture; p2_checkpoints "$fx_record" "1793318400 ${p2_label} ${other_p2} ${fx_size} ${fake_sum} token=present"; sc_encrypt_refused "$1" "exactly one ${p2_label} record"; }
sc_directory() { p2_fixture; mkdir -m 0700 "${fx_root}/other"; cp -p -- "$fx_snap" "${fx_root}/other/${p2_name}"; fx_snap="${fx_root}/other/${p2_name}"; sc_encrypt_refused "$1" "must be directly in"; }
sc_name() { p2_fixture; cp -p -- "$fx_snap" "${fx_snapdir}/${p2_name}.bak"; fx_snap="${fx_snapdir}/${p2_name}.bak"; sc_encrypt_refused "$1" "is not named as a p2 post-encryption snapshot"; }
sc_links() { p2_fixture; ln -- "$fx_snap" "${fx_root}/hard"; sc_encrypt_refused "$1" "source has other hard links"; }
sc_mode() { p2_fixture; chmod 0400 "$fx_snap"; sc_encrypt_refused "$1" "source must be mode 600"; }
sc_cap() { p2_fixture; truncate -s $(( 64 * 1024 * 1024 + 1 )) "$fx_snap"; sc_encrypt_refused "$1" "exceeds the 64 MiB cap"; }
sc_ckpt_link() { p2_fixture; mv -- "$fx_ckpt" "${fx_ckpt}.real"; ln -s "${fx_ckpt}.real" "$fx_ckpt"; sc_encrypt_refused "$1" "checkpoints file is a symbolic link"; }
sc_sudo() { p2_fixture; sc_encrypt_refused "$1" "must be encrypted through sudo" RECOVERY_MATERIAL_TEST_SUDO_USER=; }
sc_verify_refused() { # HELPER MESSAGE CIPHERTEXT SHA [NAME=VALUE...]
  local helper_path="$1" message="$2" ciphertext="$3" sum="$4"
  shift 4
  p2_helper="$helper_path" refused "$message" -- p2_verify "$@" -- --ciphertext "$ciphertext" ${sum:+--ciphertext-sha256 "$sum"} --source "$fx_snap"
}
sc_verify_sha() { p2_fixture; sc_verify_refused "$1" "does not have the expected SHA-256" "${tmp}/one-x25519.age" "$fake_sum"; }
sc_verify_required() { p2_fixture; sc_verify_refused "$1" "verify needs --ciphertext-sha256" "${tmp}/one-x25519.age" ""; }
sc_memory() { p2_fixture; meminfo 1000; sc_verify_refused "$1" "not enough available memory" "${tmp}/one-x25519.age" "$one_sum" RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/meminfo"; }
sc_tmpfs_size() { p2_fixture; meminfo 100000; sc_verify_refused "$1" "not enough available memory for the 80 MiB private tmpfs" "${tmp}/one-x25519.age" "$one_sum" RECOVERY_MATERIAL_TEST_MEMINFO="${tmp}/meminfo"; }
g_mutant_case "no checkpoint SHA-256 guard" "$helper" 's/|| die "the source SHA-256 differs from its checkpoint record"/|| :/' sc_substituted
g_mutant_case "no checkpoint size guard" "$helper" 's/|| die "the source size differs/|| : "/' sc_size
g_mutant_case "no checkpoint time guard" "$helper" 's/|| die "the source modification time differs/|| : "/' sc_mtime
g_mutant_case "no single-record guard" "$helper" 's/|| die "the checkpoints file must hold exactly one record/|| : "/' sc_one_record
# In these patterns, "." stands for a literal "$" of the helper's text.
g_mutant_case "no single-p2-record guard" "$helper" 's/|| die "the checkpoints file must hold exactly one .{SNAPSHOT_LABEL}/|| : "/' sc_one_label
g_mutant_case "no snapshot-directory binding" "$helper" 's/|| die "the stage3-p2-snapshot source must be directly in/|| : "/' sc_directory
g_mutant_case "no p2 name guard" "$helper" 's/|| die "the stage3-p2-snapshot source is not named/|| : "/' sc_name
g_mutant_case "no link-count guard" "$helper" 's/|| die "the stage3-p2-snapshot source has other hard links/|| : "/' sc_links
g_mutant_case "no mode-600 guard" "$helper" 's/|| die "the stage3-p2-snapshot source must be mode 600/|| : "/' sc_mode
g_mutant_case "no 64 MiB cap" "$helper" 's/|| die "the stage3-p2-snapshot source exceeds the 64 MiB cap/|| : "/' sc_cap
g_mutant_case "no checkpoints-link guard" "$helper" 's/|| die "the checkpoints file is a symbolic link/|| : "/' sc_ckpt_link
g_mutant_case "no sudo-operator requirement" "$helper" 's/|| require_sudo_operator ".item"/|| :/' sc_sudo
g_mutant_case "no expected-ciphertext guard in verify" "$helper" 's/|| die "the ciphertext does not have the expected SHA-256/|| : "/' sc_verify_sha
g_mutant_case "verify without --ciphertext-sha256" "$helper" 's/if \[\[ ".item" == "stage3-p2-snapshot" && -z ".expected_sha256" \]\]; then/if false; then/' sc_verify_required
g_mutant_case "no memory guard" "$helper" 's/|| die "not enough available memory/|| : "/' sc_memory
g_mutant_case "4 MiB tmpfs for the snapshot" "$helper" 's/^SNAPSHOT_TMPFS_MIB=80$/SNAPSHOT_TMPFS_MIB=4/' sc_tmpfs_size
if (( real_age_ok )); then
  p2_age_path="$PATH"
  sc_output_owner() { p2_fixture; sc_encrypt_refused "$1" "mode 600 file owned by the operator" "${key_vars[@]}" STUB_RUNUSER_CHMOD=0644; }
  sc_changed() { p2_fixture; p2_age_path="${age_wrap_dir}:${PATH}" sc_encrypt_refused "$1" "the source changed during encryption" "${key_vars[@]}" "WRAP_AGE_TOUCH=${fx_snap}"; }
  g_mutant_case "no output ownership check" "$helper" 's/^check_output() {$/check_output() { return 0/' sc_output_owner
  g_mutant_case "no post-encryption source check" "$helper" 's/die "the source changed during encryption; the ciphertext was removed"/:/' sc_changed
  unset p2_age_path
fi
sc_s3_store() { g_store="$(fresh_dir)"; cp -- "${tmp}/g-upload.age" "${g_store}/recovery_stage3-p2-snapshot_${g_date}.age"; }
sc_s3_refused() { # HELPER MESSAGE UPLOAD-ARGS...
  local helper_path="$1" message="$2"
  shift 2
  refused "$message" -- g_s3 env FAKE_AWS_STORE="$g_store" bash "$helper_path" upload --date "$g_date" --file "${tmp}/g-upload.age" "$@"
}
sc_s3_replaces() { sc_s3_store; sc_s3_refused "$1" "does not have the SHA-256 given with --replaces-sha256" --item "$p2_item" \
  --ciphertext-sha256 "$g_up_sha" --receipt "$(fresh_dir)/r" --new-version --replaces-sha256 "$fake_sum"; }
sc_s3_nv_receipt() { sc_s3_store; sc_s3_refused "$1" "--new-version needs --receipt" --item grafana-admin --new-version --replaces-sha256 "$g_up_sha"; }
sc_s3_p2_receipt() { g_store="$(fresh_dir)"; sc_s3_refused "$1" "upload needs --receipt" --item "$p2_item" --ciphertext-sha256 "$g_up_sha"; }
sc_s3_expected() { g_store="$(fresh_dir)"; sc_s3_refused "$1" "does not have the expected SHA-256" --item "$p2_item" --ciphertext-sha256 "$fake_sum" --receipt "$(fresh_dir)/r"; }
sc_s3_absent() { g_store="$(fresh_dir)"; sc_s3_refused "$1" "does not exist; --new-version" --item "$p2_item" --ciphertext-sha256 "$g_up_sha" \
  --receipt "$(fresh_dir)/r" --new-version --replaces-sha256 "$g_up_sha"; }
g_mutant_case "no replaced-version guard" "$s3_helper" 's/|| die "the current version of .{key} does not have the SHA-256/|| : "/' sc_s3_replaces
g_mutant_case "new version without a receipt" "$s3_helper" 's/|| die "--new-version needs --receipt/|| : "/' sc_s3_nv_receipt
g_mutant_case "stage3-p2-snapshot without a receipt" "$s3_helper" 's/^RECEIPT_ITEMS=(encryption-config stage3-p2-snapshot)$/RECEIPT_ITEMS=(encryption-config)/' sc_s3_p2_receipt
g_mutant_case "no expected-ciphertext guard on upload" "$s3_helper" 's/|| die "the file does not have the expected SHA-256/|| : "/' sc_s3_expected
g_mutant_case "new version for an absent key" "$s3_helper" 's/    die ".{key} does not exist; --new-version/    : "/' sc_s3_absent

echo
printf 'Recovery-material helper tests: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"

echo "Not exercised: production sudo and runuser, tmpfs mount, swap check, /dev/tty passphrase prompt, SSH, AWS, S3."
(( failed == 0 ))
