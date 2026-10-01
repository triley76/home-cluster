#!/usr/bin/env bash
# Static validation for the kube-prometheus-stack observability configuration.
#
# The source of truth for chart values is the Flux HelmRelease under
# clusters/home/monitoring/controllers/. When clusters/home/monitoring does not
# exist yet (observability Phase 1), the script runs in fixture mode against
# scripts/testdata/observability/ to prove the validation mechanism only. Fixture
# mode does NOT validate any monitoring configuration.
#
# Checks:
#   - the pinned chart package matches its recorded SHA-256 before use;
#   - the HelmRelease pins the same chart version as this script, and uses no
#     valuesFrom, chart valuesFiles or postRenderers (which this render would not apply);
#   - every enabled image is pinned explicitly in spec.values to the version listed in
#     scripts/observability-image-pins.yaml, and that version is approved in the
#     Versions table of docs/design/observability.md;
#   - `helm template --include-crds` renders the chart with the HelmRelease values,
#     including at least one CustomResourceDefinition;
#   - kubeconform validates the rendered resources (CRDs are counted, not schema-checked);
#   - the rendered chart contains the approved full reference of every enabled pin, and
#     independently, every rendered container image has an explicit, non-latest tag or a digest;
#   - promtool checks repository PrometheusRules with fatal duplicate-rule lint, and
#     chart-rendered rules for syntax, accepting only exact known chart lint findings;
#   - every dashboard JSON file parses;
#   - no Secret manifest is committed under the monitoring directory.
#
# Static only: this does not show scheduling, storage binding, scrape success,
# webhook behaviour, or rule behaviour on a cluster.
#
# Requires: helm, kubeconform, promtool, python3 with PyYAML, sha256sum, curl
set -euo pipefail

# Chart pin. Selected for validation on 2026-09-30. The SHA-256 is the
# digest published in https://prometheus-community.github.io/helm-charts/index.yaml
# and was independently recomputed from the downloaded package.
KPS_CHART_VERSION="91.8.2"
KPS_CHART_SHA256="dbd50ecc4b3c4a0231d8a7c766d4fd8690be4bf2230acb572849fae129797a23"
KPS_CHART_URL="https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KPS_CHART_VERSION}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz"
# Kubernetes version passed to helm template (the live cluster runs K3s v1.36.4).
HELM_KUBE_VERSION="1.36.4"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=scripts/validation-env.sh
source scripts/validation-env.sh

MONITORING_DIR="${OBSERVABILITY_DIR:-clusters/home/monitoring}"
FIXTURE_DIR="scripts/testdata/observability"
DESIGN_DOC="${OBSERVABILITY_DESIGN_DOC:-docs/design/observability.md}"
IMAGE_PINS="scripts/observability-image-pins.yaml"
checks="scripts/observability_checks.py"

if [ -d "$MONITORING_DIR" ]; then
  mode="repository"
  root="$MONITORING_DIR"
else
  mode="fixture"
  root="$FIXTURE_DIR"
  echo "::notice::${MONITORING_DIR} does not exist: fixture mode. Validating the CI mechanism against ${FIXTURE_DIR} only; this does NOT validate a monitoring configuration."
fi
echo "mode: ${mode} (${root})"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "::group::Chart ${KPS_CHART_VERSION} (SHA-256 pinned)"
chart="${work}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz"
if [ -n "${KPS_CHART_TGZ:-}" ]; then
  cp "$KPS_CHART_TGZ" "$chart"
else
  curl -fsSL -o "$chart" "$KPS_CHART_URL"
fi
if ! echo "${KPS_CHART_SHA256}  ${chart}" | sha256sum -c -; then
  echo "::error::chart package SHA-256 mismatch for kube-prometheus-stack ${KPS_CHART_VERSION}"
  exit 1
fi
echo "::endgroup::"

echo "::group::Secrets"
mapfile -t manifests < <(find "$root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
if [ "${#manifests[@]}" -gt 0 ]; then
  python3 "$checks" no-secrets "${manifests[@]}"
fi
echo "no Secret manifests"
echo "::endgroup::"

echo "::group::HelmRelease values"
controllers="${root}/controllers"
if [ ! -d "$controllers" ]; then
  echo "::error::${controllers} does not exist; the kube-prometheus-stack HelmRelease cannot be located"
  exit 1
fi
if ! python3 "$checks" helmrelease "$controllers" "${work}/values.yaml" > "${work}/hr.env"; then
  cat "${work}/hr.env"
  exit 1
fi
cat "${work}/hr.env"
hr_release="$(sed -n 's/^release=//p' "${work}/hr.env")"
hr_namespace="$(sed -n 's/^namespace=//p' "${work}/hr.env")"
hr_version="$(sed -n 's/^version=//p' "${work}/hr.env")"
if [ "$hr_version" != "$KPS_CHART_VERSION" ]; then
  echo "::error::HelmRelease pins chart ${hr_version} but CI pins ${KPS_CHART_VERSION}; update KPS_CHART_VERSION and KPS_CHART_SHA256 in the same PR"
  exit 1
fi
echo "::endgroup::"

echo "::group::Image pins (source values)"
python3 "$checks" image-pins "${work}/values.yaml" "$IMAGE_PINS" "$DESIGN_DOC"
echo "::endgroup::"

echo "::group::helm template"
if ! helm template "$hr_release" "$chart" \
    --namespace "$hr_namespace" \
    --kube-version "$HELM_KUBE_VERSION" \
    --api-versions monitoring.coreos.com/v1 \
    --include-crds \
    --values "${work}/values.yaml" > "${work}/rendered.yaml"; then
  echo "::error::helm template failed for kube-prometheus-stack ${KPS_CHART_VERSION} with the HelmRelease values"
  exit 1
fi
crd_count="$(grep -c '^kind: CustomResourceDefinition$' "${work}/rendered.yaml" || true)"
echo "rendered $(grep -c '^kind:' "${work}/rendered.yaml") objects"
echo "CustomResourceDefinitions rendered: ${crd_count}"
if [ "$crd_count" -eq 0 ]; then
  echo "::error::no CustomResourceDefinitions rendered; kube-prometheus-stack ${KPS_CHART_VERSION} must include its CRDs"
  exit 1
fi
echo "::endgroup::"

echo "::group::kubeconform (rendered chart)"
if ! kubeconform \
    -strict \
    -summary \
    -skip CustomResourceDefinition \
    -kubernetes-version "$KUBERNETES_VERSION" \
    -schema-location default \
    -schema-location "$CRD_SCHEMA_LOCATION" \
    "${work}/rendered.yaml"; then
  echo "::error::rendered kube-prometheus-stack resources failed schema validation"
  exit 1
fi
echo "::endgroup::"

echo "::group::Image references (rendered)"
python3 "$checks" image-refs "${work}/rendered.yaml" "${work}/values.yaml" "$IMAGE_PINS"
python3 "$checks" images "${work}/rendered.yaml"
echo "::endgroup::"

echo "::group::PrometheusRules (promtool)"
# Counts go to files and diagnostics to stdout, so a failure here is always visible.
python3 "$checks" rules "${work}/rules/repo" "${work}/rules-repo.count" "${manifests[@]}" /dev/null
python3 "$checks" rules "${work}/rules/chart" "${work}/rules-chart.count" "${work}/rendered.yaml"
echo "PrometheusRule objects: $(cat "${work}/rules-repo.count") in ${root}, $(cat "${work}/rules-chart.count") rendered by the chart"
shopt -s nullglob
# Repository-owned rules: syntax and duplicate-rule lint are both fatal.
repo_rule_files=("${work}"/rules/repo/*.rules.yaml)
if [ "${#repo_rule_files[@]}" -eq 0 ]; then
  echo "no repository PrometheusRule content present; promtool check skipped"
elif ! promtool check rules --lint=duplicate-rules --lint-fatal "${repo_rule_files[@]}"; then
  echo "::error::promtool rejected repository PrometheusRule content"
  exit 1
fi
# Chart-owned rules: syntax errors are fatal; lint findings fail unless they are an
# exact known finding for the pinned chart (see KNOWN_CHART_LINT).
chart_rule_files=("${work}"/rules/chart/*.rules.yaml)
if [ "${#chart_rule_files[@]}" -eq 0 ]; then
  echo "no chart PrometheusRule content present; promtool check skipped"
else
  set +e
  promtool check rules --lint=duplicate-rules "${chart_rule_files[@]}" > "${work}/promtool-chart.out" 2>&1
  rc=$?
  set -e
  cat "${work}/promtool-chart.out"
  if [ "$rc" -ne 0 ]; then
    echo "::error::promtool rejected chart-rendered PrometheusRule content"
    exit 1
  fi
  python3 "$checks" chart-lint "${work}/promtool-chart.out"
fi
echo "::endgroup::"

echo "::group::Dashboards (JSON)"
mapfile -t dashboards < <(find "$root" -type f -name '*.json' | sort)
if [ "${#dashboards[@]}" -eq 0 ]; then
  echo "no dashboard JSON files present; check skipped"
else
  python3 "$checks" dashboards "${dashboards[@]}"
fi
echo "::endgroup::"

echo "observability validation passed (${mode} mode)"
