#!/usr/bin/env bash
# Tear down the kind cluster shared by all OCI mirror demos. The cluster
# is shared across mirror tools, so this is the same operation for each;
# tearing down one mirror tears down all of them.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi
