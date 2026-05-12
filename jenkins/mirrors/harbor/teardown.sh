#!/usr/bin/env bash
# Tear down the kind cluster shared by all OCI mirror demos. The cluster
# name was renamed from `jenkins-harbor` to `jenkins-mirrors` when the
# layout was generalized to support multiple tools.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi
