#!/usr/bin/env bash
# Tear down the kind cluster shared by all OCI mirror demos. Same shape
# as mirrors/harbor/teardown.sh — the cluster is shared across tools, so
# any mirror's teardown.sh deletes the whole cluster.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi

# Clean up the per-tool secrets dir (admin password file).
SECRETS_DIR="${SECRETS_DIR:-/tmp/cgjenkins-home/.secrets/jcr}"
if [[ -d "$SECRETS_DIR" ]]; then
  echo "==> Removing JCR secrets dir ${SECRETS_DIR}..."
  rm -rf "$SECRETS_DIR"
fi
