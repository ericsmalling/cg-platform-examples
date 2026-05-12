#!/usr/bin/env bash
# Deploy a JFrog Container Registry (JCR) instance into the shared kind
# cluster, configured to proxy cgr.dev/${CHAINGUARD_ORG}/* via a Docker
# remote repo named "cgr-proxy" backed by the in-cluster cgr-oidc-proxy.
# Also creates a "library" Docker local repo as a push target and a
# "library-group" virtual repo aggregating both.
#
# Pull-token model: same as the other mirror tools — kubelet reaches
# cgr.dev via a containerd registry mirror that points at the
# cgr-oidc-proxy. JCR reaches it via the cluster Service. The proxy holds
# a projected ServiceAccount token, exchanges it at Chainguard's STS for
# a short-lived registry bearer, and injects it on outbound requests. No
# long-lived cgr.dev credentials live anywhere on disk.
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org to proxy (e.g. 'chainguard' or 'your-org.example.com')
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-mirrors
#
# License caveat: JCR is JFrog's free non-commercial Docker-capable tier of
# Artifactory. Demo / evaluation use only — do not use this in production
# without a paid license.
#
# Idempotent: re-running re-applies the manifests and re-PUTs the repo
# config (Artifactory PUT is idempotent).
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"

# Tools used here in addition to those required by the shared bootstrap.
for tool in curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH" >&2
    exit 1
  fi
done

# JCR's namespace under the new layout: each mirror tool has its own
# `mirror-<name>` namespace. The shared cgr-oidc-proxy ns is created by
# the bootstrap.
JCR_NAMESPACE="mirror-jcr"
export MIRROR_NAMESPACE="$JCR_NAMESPACE"

# Pull in the shared bootstrap library — kind cluster, JWKS capture,
# chainguard_identity (terraform stage 1), proxy ConfigMap, proxy build +
# load + deploy. COMMON_DIR auto-derives from BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + cgr-oidc-proxy + identity) -------
common::bootstrap_all

# ---- Stage 2: JCR-specific (PVC + Deployment + Service) -----------------

echo "==> Applying JCR manifests in namespace ${JCR_NAMESPACE}..."
kubectl apply -f k8s/

echo "==> Waiting for JCR rollout (this can take 4-5 minutes on a cold start)..."
# rollout-status --timeout must be >= the Deployment's progressDeadlineSeconds
# (1200s = 20m, set in k8s/deployment.yaml). A shorter client timeout
# returns "exceeded its progress deadline" before the controller has
# actually given up.
kubectl -n "$JCR_NAMESPACE" rollout status deployment/jcr --timeout=20m

echo "==> Configuring JCR Docker repos via REST API..."
"$SCRIPT_DIR/bootstrap-repos.sh"

echo "==> Done."
echo "    JCR UI:               http://localhost:8082 (admin / password — CE can't rotate via REST)"
echo "    Pull through cgr.dev: localhost:5054/cgr-proxy/<image>:<tag>"
echo "    Push hosted target:   localhost:5054/library/<image>:<tag>"
echo "    Unified group repo:   localhost:5054/library-group/<image>:<tag>"
echo "    cgr.dev proxy:        cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
echo "    Note: JCR is slow — first start can take 4-5 minutes."
