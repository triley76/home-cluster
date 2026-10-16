#!/usr/bin/env bash
# Functional tests for scripts/recovery-material.sh and scripts/recovery-material-s3.sh.
#
# Group A: refusal paths, using a stub `age` that only reports its version.
# Group B: real encrypt and verify round trips with a throwaway identity generated
#          at runtime. Needs age and age-keygen v1.3.2; skipped when they are absent,
#          unless RECOVERY_MATERIAL_REQUIRE_AGE=1 (as in CI), which makes absence a failure.
# Group C: the S3 helper against a stub `aws` command.
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

# expect NAME STATUS MESSAGE -- COMMAND...: STATUS is "ok", "fail" or a number; MESSAGE
# must appear in the combined output (empty to skip). Output must never contain the
# plaintext sentinel, the fake account ID or the fake bucket name.
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
  if grep -qF -e "$sentinel" -e "$fake_account" -e "$fake_bucket" "${tmp}/out"; then
    fail "$name" "output contained a value that must never be printed"
    return 0
  fi
  pass "$name"
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

echo
printf 'Recovery-material helper tests: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
echo "Not exercised: production sudo and runuser, tmpfs mount, swap check, /dev/tty passphrase prompt, SSH, AWS, S3."
(( failed == 0 ))
