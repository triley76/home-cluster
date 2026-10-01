# Shared schema-validation settings, sourced by the validation scripts.
# shellcheck shell=bash

# The cluster runs K3s v1.36.4; 1.34.11 is the newest release published in the
# upstream kubernetes-json-schema set. Raise this when newer schemas appear.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.34.11}"
# Pinned commit of https://github.com/datreeio/CRDs-catalog for Flux, MetalLB and
# Prometheus Operator schemas.
CRD_CATALOG_REF="${CRD_CATALOG_REF:-ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2}"
CRD_SCHEMA_LOCATION="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
