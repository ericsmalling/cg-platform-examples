#!/usr/bin/env bash
# Tear down the kind cluster shared by all OCI mirror demos. zot has no
# external state — the whole registry lives in an emptyDir inside the pod,
# which dies with the cluster. Symmetric with mirrors/harbor/teardown.sh.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi
