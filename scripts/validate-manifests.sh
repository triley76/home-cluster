#!/usr/bin/env bash
# Render every Kustomize directory under clusters/ and validate the output
# against Kubernetes and CRD JSON schemas.
#
# This is static validation only. It confirms that manifests render and match
# their schemas; it does not prove apply ordering, CRD availability at apply
# time, Flux dependency behavior, or clean-bootstrap success.
#
# CustomResourceDefinition objects are skipped because no maintained JSON schema
# exists for that kind; kubeconform reports them in its Skipped count.
#
# Requires: kustomize, kubeconform
set -euo pipefail

# The cluster runs K3s v1.36.4; 1.34.11 is the newest release published in the
# upstream kubernetes-json-schema set. Raise this when newer schemas appear.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.34.11}"
# Pinned commit of https://github.com/datreeio/CRDs-catalog for Flux and MetalLB schemas.
CRD_CATALOG_REF="${CRD_CATALOG_REF:-ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2}"
CRD_SCHEMA_LOCATION="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

status=0
while IFS= read -r kfile; do
  dir="$(dirname "$kfile")"
  echo "::group::${dir}"
  if ! kustomize build "$dir" | kubeconform \
      -strict \
      -summary \
      -skip CustomResourceDefinition \
      -kubernetes-version "$KUBERNETES_VERSION" \
      -schema-location default \
      -schema-location "$CRD_SCHEMA_LOCATION"; then
    echo "::error::validation failed for ${dir}"
    status=1
  fi
  echo "::endgroup::"
done < <(find clusters -name kustomization.yaml -type f | sort)

exit "$status"
