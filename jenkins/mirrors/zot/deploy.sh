#!/usr/bin/env bash
# Deploy a project-zot registry into the shared kind cluster, configured as
# both:
#   * a pull-through cache for cgr.dev/${CHAINGUARD_ORG}/* via zot's sync
#     extension, going through the in-cluster cgr-oidc-proxy (which holds
#     the short-lived Chainguard bearer derived from a projected k8s SA
#     JWT — no long-lived pull tokens anywhere); and
#   * a hosted registry for pipeline pushes, served from the same instance
#     under a `library/` path prefix to disambiguate from synced upstream
#     content.
#
# A single zot Deployment serves both roles. With `prefix: "<org>/**"` and
# `stripPrefix: true`, zot maps cgr.dev/<org>/<image> → localhost:5052/<image>
# for sync, while pushes to localhost:5052/library/<image> land in zot's
# local storage (no upstream prefix match → not synced; treated as hosted).
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org to proxy (e.g. 'chainguard' or 'your-org.example.com')
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-mirrors
#
# Idempotent: re-running re-applies the manifests with up-to-date inputs.
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"

# Each mirror tool gets its own `mirror-<name>` namespace under the new
# layout. The shared cgr-oidc-proxy ns is created by the bootstrap.
ZOT_NAMESPACE="mirror-zot"
export MIRROR_NAMESPACE="$ZOT_NAMESPACE"

# Pull in the shared bootstrap library — kind cluster, JWKS capture,
# chainguard_identity (terraform stage 1), proxy ConfigMap, proxy build +
# load + deploy. COMMON_DIR auto-derives from BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + cgr-oidc-proxy + identity) -------
common::bootstrap_all

# ---- Stage 2: zot-specific manifests ------------------------------------

echo "==> Rendering zot ConfigMap with CHAINGUARD_ORG=${CHAINGUARD_ORG}..."
# envsubst expands ${CHAINGUARD_ORG} into the sync prefix; nothing else in
# the template uses shell-style $VAR so this is safe.
CHAINGUARD_ORG="$CHAINGUARD_ORG" envsubst '${CHAINGUARD_ORG}' \
  < k8s/configmap.yaml.template > k8s/configmap.yaml

echo "==> Applying zot manifests..."
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Bounce the deployment so a re-run picks up an updated ConfigMap.
kubectl -n "$ZOT_NAMESPACE" rollout restart deployment/zot
kubectl -n "$ZOT_NAMESPACE" rollout status deployment/zot --timeout=3m

echo "==> Done."
echo "    Pull through cgr.dev:  localhost:5052/<image>:<tag>"
echo "    Push hosted target:    localhost:5052/library/<image>:<tag>"
echo "    cgr.dev proxy:         cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
