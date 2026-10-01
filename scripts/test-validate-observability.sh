#!/usr/bin/env bash
# Positive and negative tests for scripts/validate-observability.sh.
#
# Every case runs against a temporary copy of the fixtures (OBSERVABILITY_DIR) and
# a local copy of the chart package (KPS_CHART_TGZ). Negative cases must fail with
# their expected message, so a case cannot pass by failing for an unrelated reason.
# The tracked working tree must be unchanged afterwards.
#
# Requires: the same tools as validate-observability.sh, plus git.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fixtures="scripts/testdata/observability"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

before="$(git status --porcelain --untracked-files=all; git diff | sha256sum)"

# Chart package, fetched once and verified by the validator in every case.
version="$(sed -n 's/^KPS_CHART_VERSION="\(.*\)"$/\1/p' scripts/validate-observability.sh)"
url="$(sed -n 's/^KPS_CHART_URL="\(.*\)"$/\1/p' scripts/validate-observability.sh | sed "s/\${KPS_CHART_VERSION}/${version}/g")"
curl -fsSL -o "${tmp}/chart.tgz" "$url"

pass=0
fail=0

# case_run <name> <expect: pass|fail> <expected output substring> <monitoring dir> [chart tgz] [design doc]
case_run() {
  local name=$1 expect=$2 needle=$3 dir=$4 tgz=${5:-${tmp}/chart.tgz} design=${6:-docs/design/observability.md} out rc
  set +e
  out="$(OBSERVABILITY_DIR="$dir" KPS_CHART_TGZ="$tgz" OBSERVABILITY_DESIGN_DOC="$design" \
    bash scripts/validate-observability.sh 2>&1)"
  rc=$?
  set -e
  if { [ "$expect" = pass ] && [ $rc -eq 0 ]; } || { [ "$expect" = fail ] && [ $rc -ne 0 ]; }; then
    if grep -qF -- "$needle" <<< "$out"; then
      echo "PASS  ${name} (exit ${rc})"
      pass=$((pass + 1))
      return
    fi
    echo "FAIL  ${name}: exit ${rc} as expected, but output lacks: ${needle}"
  else
    echo "FAIL  ${name}: expected ${expect}, got exit ${rc}"
  fi
  printf '%s\n' "$out" | tail -n 15 | sed 's/^/      | /'
  fail=$((fail + 1))
}

# new_dir <name>: a fresh copy of the fixtures laid out like clusters/home/monitoring.
new_dir() {
  local d="${tmp}/$1"
  mkdir -p "$d"
  cp -r "${fixtures}/." "$d/"
  echo "$d"
}

hr() { echo "$1/controllers/kube-prometheus-stack.yaml"; }
rule() { echo "$1/configs/prometheusrule.yaml"; }

# edit_yaml <file> <python statements>: edit the first document, available as `doc`.
edit_yaml() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path, code = sys.argv[1], sys.argv[2]
with open(path) as f:
    docs = list(yaml.safe_load_all(f))
exec(code, {"doc": docs[0]})
with open(path, "w") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False)
PY
}

# --- positive -------------------------------------------------------------------
case_run "fixture mode when the monitoring directory is absent" pass \
  "observability validation passed (fixture mode)" "${tmp}/does-not-exist"

d="$(new_dir repo-mode)"
case_run "repository mode with a valid HelmRelease, rule and dashboard" pass \
  "observability validation passed (repository mode)" "$d"
case_run "explicit image pins are enforced on the source values" pass \
  "pinned: prometheus.prometheusSpec.image -> quay.io/prometheus/prometheus:v3.15.0-distroless (approved in design row '| Prometheus |')" "$d"
case_run "CRDs are included in the render" pass "CustomResourceDefinitions rendered: " "$d"
case_run "rendered chart contains the approved node-exporter distroless reference" pass \
  "rendered: quay.io/prometheus/node-exporter:v1.12.1-distroless" "$d"
case_run "known chart lint finding is accepted as a warning" pass \
  "::warning::known chart lint finding accepted (" "$d"

GRAFANA_PHASE3='doc["spec"]["values"]["grafana"] = {
    "enabled": True,
    "image": {"registry": "docker.io", "repository": "grafana/grafana", "tag": "13.2.3-distroless"},
    "sidecar": {"image": {"registry": "quay.io", "repository": "kiwigrid/k8s-sidecar", "tag": "2.11.2"}},
    "initChownData": {"image": {"registry": "docker.io", "repository": "library/busybox", "tag": "1.38.0"}},
    "persistence": {"enabled": True, "storageClassName": "local-path", "size": "1Gi"},
    "testFramework": {"enabled": False}}'
d="$(new_dir grafana-phase3)"
edit_yaml "$(hr "$d")" "$GRAFANA_PHASE3"
case_run "Phase 3-shaped Grafana values with approved images, including busybox" pass \
  "rendered: docker.io/library/busybox:1.38.0" "$d"

d="$(new_dir grafana-test-framework)"
edit_yaml "$(hr "$d")" "$GRAFANA_PHASE3"'
doc["spec"]["values"]["grafana"]["testFramework"] = {"enabled": True,
    "image": {"registry": "docker.io", "repository": "bats/bats", "tag": "1.14.0"}}'
case_run "Grafana test framework enabled (no approved image)" fail \
  "image pin: grafana.testFramework.image: docker.io/bats/bats:1.14.0 is not approved in the design Versions table row" "$d"

# --- negative: HelmRelease structure and rendering parity -------------------------
d="$(new_dir values-not-mapping)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"] = ["not", "a", "mapping"]'
case_run "HelmRelease values that are not a mapping" fail "spec.values must be a mapping" "$d"

d="$(new_dir values-missing)"
edit_yaml "$(hr "$d")" 'del doc["spec"]["values"]'
case_run "HelmRelease without spec.values" fail "spec.values is missing" "$d"

d="$(new_dir values-from)"
edit_yaml "$(hr "$d")" 'doc["spec"]["valuesFrom"] = [{"kind": "ConfigMap", "name": "extra-values"}]'
case_run "HelmRelease using valuesFrom" fail "spec.valuesFrom is not supported" "$d"

d="$(new_dir values-files)"
edit_yaml "$(hr "$d")" 'doc["spec"]["chart"]["spec"]["valuesFiles"] = ["values-extra.yaml"]'
case_run "HelmRelease using chart valuesFiles" fail "spec.chart.spec.valuesFiles is not supported" "$d"

d="$(new_dir post-renderers)"
edit_yaml "$(hr "$d")" 'doc["spec"]["postRenderers"] = [{"kustomize": {"patches": []}}]'
case_run "HelmRelease using postRenderers" fail "spec.postRenderers is not supported" "$d"

d="$(new_dir no-helmrelease)"
rm "$(hr "$d")"
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: monitoring\n' > "$d/controllers/namespace.yaml"
case_run "controllers directory without the HelmRelease" fail "expected exactly one HelmRelease" "$d"

d="$(new_dir version-mismatch)"
sed -i 's/version: "91.8.2"/version: "91.8.1"/' "$(hr "$d")"
case_run "HelmRelease chart version differs from the CI pin" fail "update KPS_CHART_VERSION" "$d"

d="$(new_dir template-error)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["additionalScrapeConfigs"] = "{{ .Values.unclosed"'
case_run "values that break helm template" fail "helm template failed" "$d"

d="$(new_dir schema-invalid)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["replicas"] = "two"'
case_run "values that render a schema-invalid Prometheus" fail "failed schema validation" "$d"

d="$(new_dir no-crds)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["crds"] = {"enabled": False}'
case_run "values that render no CRDs" fail "no CustomResourceDefinitions rendered" "$d"

# --- negative: explicit image pins ------------------------------------------------
d="$(new_dir pin-missing)"
edit_yaml "$(hr "$d")" 'del doc["spec"]["values"]["prometheus"]["prometheusSpec"]["image"]'
case_run "missing explicit image pin" fail \
  "image pin: prometheus.prometheusSpec.image: image is not pinned explicitly in spec.values" "$d"

d="$(new_dir pin-empty-tag)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["image"]["tag"] = ""'
case_run "empty image tag" fail "image pin: prometheus.prometheusSpec.image.tag: missing or empty" "$d"

d="$(new_dir pin-latest)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["image"]["tag"] = "latest"'
case_run "image tag latest" fail "image pin: prometheus.prometheusSpec.image.tag: latest is not allowed" "$d"

d="$(new_dir pin-wrong-version)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["image"]["tag"] = "v3.14.0"'
case_run "image pinned to an unapproved version" fail \
  "image pin: prometheus.prometheusSpec.image.tag: expected 'v3.15.0-distroless', found 'v3.14.0'" "$d"

d="$(new_dir pin-not-in-design)"
sed 's|`quay.io/prometheus/prometheus:v3.15.0-distroless`|`quay.io/prometheus/prometheus:v3.16.0-distroless`|' \
  docs/design/observability.md > "${tmp}/design-drift.md"
case_run "pin not approved by the design Versions table" fail \
  "is not approved in the design Versions table row" "$d" "${tmp}/chart.tgz" "${tmp}/design-drift.md"

d="$(new_dir node-exporter-not-distroless)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus-node-exporter"]["image"]["distroless"] = False'
case_run "node-exporter forced to the non-distroless variant" fail \
  "image reference: prometheus-node-exporter.image: rendered chart does not contain the approved reference quay.io/prometheus/node-exporter:v1.12.1-distroless" "$d"

d="$(new_dir rendered-untagged)"
edit_yaml "$(hr "$d")" 'doc["spec"]["values"]["prometheus"]["prometheusSpec"]["initContainers"] = [{"name": "extra", "image": "busybox"}]'
case_run "rendered image check catches an image outside the pinned paths" fail \
  "image without an explicit tag or digest, or tagged latest" "$d"

# --- negative: rules, dashboards, secrets, checksum --------------------------------
d="$(new_dir bad-rule)"
sed -i 's/expr: vector(0) > 1/expr: rate(up[5m]/' "$(rule "$d")"
case_run "malformed PrometheusRule expression" fail "promtool rejected repository PrometheusRule content" "$d"

DUPLICATE_RECORDING='[{"name": "dup", "rules": [
    {"record": "ci:fixture:dup", "expr": "vector(1)"},
    {"record": "ci:fixture:dup", "expr": "vector(1)"}]}]'
d="$(new_dir repo-duplicate-rule)"
edit_yaml "$(rule "$d")" "doc[\"spec\"][\"groups\"] += ${DUPLICATE_RECORDING}"
case_run "duplicate rule in a repository PrometheusRule (fatal lint)" fail \
  "promtool rejected repository PrometheusRule content" "$d"

d="$(new_dir chart-unexpected-lint)"
edit_yaml "$(hr "$d")" "doc[\"spec\"][\"values\"][\"additionalPrometheusRulesMap\"] = {\"ci-unexpected\": {\"groups\": ${DUPLICATE_RECORDING}}}"
case_run "unexpected duplicate in chart-rendered rules fails" fail \
  "::error::unexpected chart rule lint finding in " "$d"

d="$(new_dir rule-groups-missing)"
edit_yaml "$(rule "$d")" 'del doc["spec"]["groups"]'
case_run "PrometheusRule without spec.groups" fail \
  "::error::${d}/configs/prometheusrule.yaml: PrometheusRule ci-fixture has missing or empty spec.groups" "$d"

d="$(new_dir rule-groups-empty)"
edit_yaml "$(rule "$d")" 'doc["spec"]["groups"] = []'
case_run "PrometheusRule with empty spec.groups" fail \
  "::error::${d}/configs/prometheusrule.yaml: PrometheusRule ci-fixture has missing or empty spec.groups" "$d"

d="$(new_dir bad-dashboard)"
printf '{"title": "broken", "panels": [\n' > "$d/configs/dashboards/ci-fixture.json"
case_run "malformed dashboard JSON" fail "invalid dashboard JSON" "$d"

d="$(new_dir committed-secret)"
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\nstringData:\n  admin-password: fixture\n' \
  > "$d/controllers/secret.yaml"
case_run "Secret manifest in the monitoring directory" fail "must not be committed" "$d"

cp "${tmp}/chart.tgz" "${tmp}/tampered.tgz"
printf 'tampered' >> "${tmp}/tampered.tgz"
d="$(new_dir checksum)"
case_run "chart package SHA-256 mismatch" fail "SHA-256 mismatch" "$d" "${tmp}/tampered.tgz"

# --- tracked working tree unchanged -----------------------------------------------
after="$(git status --porcelain --untracked-files=all; git diff | sha256sum)"
if [ "$before" = "$after" ]; then
  echo "PASS  tracked working tree unchanged"
  pass=$((pass + 1))
else
  echo "FAIL  tracked working tree changed during the tests"
  fail=$((fail + 1))
fi

echo "results: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
