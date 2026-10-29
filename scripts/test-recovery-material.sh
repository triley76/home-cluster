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
#
# Every run uses RECOVERY_MATERIAL_TEST=1 overrides or stubs. These tests do NOT
# exercise production sudo or runuser, the tmpfs mount, the swap check, the /dev/tty
# passphrase prompt, SSH, AWS or S3. Fixtures that look like secrets are assembled at runtime.
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
key="" body="" version="" checksum="" bucket="" outfile=""
# Every remaining option takes a value; the first bare word is the positional
# outfile (get-object), wherever it appears.
for ((i = 2; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --bucket) bucket="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --key) key="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --body) body="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --version-id) version="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --checksum-sha256) checksum="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --*) i=$((i + 1)) ;;
    *) [[ -z "$outfile" ]] && outfile="${args[$i]}" ;;
  esac
done
error() {
  echo "An error occurred ($1) when calling the $2 operation: User: ${FAKE_AWS_ARN} is not authorized on ${bucket}" >&2
  exit 254
}
[[ -z "${FAKE_AWS_FAIL:-}" || "$service $operation" == "sts get-caller-identity" ]] || error "$FAKE_AWS_FAIL" "$operation"
object="${FAKE_AWS_STORE}/$(printf '%s' "$key" | tr '/' '_')"
case "$service $operation" in
  "sts get-caller-identity") echo "$FAKE_AWS_ARN" ;;
  "s3api head-object") [[ -f "$object" ]] && echo '{}' || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; } ;;
  "s3api put-object")
    actual="$(python3 -c 'import base64,hashlib,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$body")"
    [[ "$actual" == "$checksum" ]] || error BadDigest PutObject
    cp -- "$body" "$object"
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
    printf '%s\n' "${FAKE_AWS_VERSION:-stub-version-1}" ;;
  "s3api get-object")
    [[ "$version" == "stub-version-1" && -f "$object" ]] || error NoSuchVersion GetObject
    [[ -n "$outfile" ]] || { echo "stub aws: no outfile" >&2; exit 2; }
    cp -- "$object" "$outfile"
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
for kind in fifo devnull dangling filelink; do
  expect "encryption-config: a ${kind} receipt that appears during upload is not written" 1 "receipt could not be written" -- \
    s3_private env FAKE_AWS_PLANT="${receipts}/race-${kind}.receipt" FAKE_AWS_PLANT_KIND="$kind" \
    timeout 20 bash "$s3_helper" upload --item "$item" --date "$race" --file "${tmp}/ec-upload.age" \
    --receipt "${receipts}/race-${kind}.receipt" --new-version
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

echo
printf 'Recovery-material helper tests: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"

echo "Not exercised: production sudo and runuser, tmpfs mount, swap check, /dev/tty passphrase prompt, SSH, AWS, S3."
(( failed == 0 ))
