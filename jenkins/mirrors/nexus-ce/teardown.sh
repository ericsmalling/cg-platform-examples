#!/usr/bin/env bash
# Tear down the kind cluster shared by all OCI mirror demos. Same shape as
# the other mirrors' teardown.sh — the cluster is shared, so deleting it
# wipes Nexus along with everything else. Also cleans up the per-tool
# admin-password secret on the host.
set -euo pipefail
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
SECRETS_DIR="${SECRETS_DIR:-/tmp/cgjenkins-home/.secrets/nexus-ce}"

if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "==> Deleting kind cluster '$KIND_CLUSTER_NAME'..."
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  echo "kind cluster '$KIND_CLUSTER_NAME' not present — nothing to do."
fi

if [[ -d "$SECRETS_DIR" ]]; then
  echo "==> Removing $SECRETS_DIR..."
  rm -rf "$SECRETS_DIR"
fi
