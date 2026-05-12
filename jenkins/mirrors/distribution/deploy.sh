#!/usr/bin/env bash
# Deploy distribution/distribution into the shared kind cluster as both a
# pull-through proxy (port 5050) and a separate hosted registry (port 5051).
# The proxy points its `proxy.remoteurl` at the in-cluster cgr-oidc-proxy,
# which holds a projected ServiceAccount JWT, exchanges it at Chainguard's
# STS for a short-lived registry bearer, and injects it on every outbound
# request to cgr.dev. No long-lived pull token lives anywhere on disk.
#
# Required env vars:
#   CHAINGUARD_ORG     Chainguard org being proxied (e.g. 'your-org.example.com')
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-mirrors
#   DISTRIBUTION_IMAGE default: cgr.dev/${CHAINGUARD_ORG}/distribution:3
#                      Override (e.g. registry:3.1.1) if the Chainguard image
#                      isn't available in the configured org.
#
# Idempotent: re-running re-applies the manifests + ConfigMaps.
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"

# Default image: Chainguard's distribution. Fall back to Docker Hub's
# upstream `registry:3.1.1` if the user's org doesn't have it.
DISTRIBUTION_IMAGE="${DISTRIBUTION_IMAGE:-cgr.dev/${CHAINGUARD_ORG}/distribution:3}"
export DISTRIBUTION_IMAGE

# Each mirror tool has its own ns under the new layout.
DISTRIBUTION_NAMESPACE="mirror-distribution"
export MIRROR_NAMESPACE="$DISTRIBUTION_NAMESPACE"

# Pull in the shared bootstrap library — kind cluster, JWKS capture,
# chainguard_identity (terraform stage 1), proxy ConfigMap, proxy build +
# load + deploy. COMMON_DIR auto-derives from BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + cgr-oidc-proxy + identity) -------
common::require_tools
common::ensure_kind_cluster
common::ensure_namespaces       # creates cgr-oidc-proxy + ingress-nginx + mirror-distribution
common::capture_jwks
PROXY_UIDP="$(common::terraform_identity)"
common::ensure_proxy_configmap "$PROXY_UIDP"
common::build_and_load_proxy
common::deploy_proxy            # waits for the proxy to be Ready

# ---- Stage 2: distribution-specific (proxy + hosted Deployments) --------

echo "==> Rendering distribution manifests with DISTRIBUTION_IMAGE=${DISTRIBUTION_IMAGE}..."
envsubst '${DISTRIBUTION_IMAGE}' < k8s/proxy/deployment.yaml.template  > k8s/proxy/deployment.yaml
envsubst '${DISTRIBUTION_IMAGE}' < k8s/hosted/deployment.yaml.template > k8s/hosted/deployment.yaml

echo "==> Applying distribution-proxy manifests..."
kubectl apply -f k8s/proxy/configmap.yaml
kubectl apply -f k8s/proxy/deployment.yaml
kubectl apply -f k8s/proxy/service.yaml

echo "==> Applying distribution-hosted manifests..."
kubectl apply -f k8s/hosted/configmap.yaml
kubectl apply -f k8s/hosted/deployment.yaml
kubectl apply -f k8s/hosted/service.yaml

echo "==> Waiting for distribution-proxy to be Ready..."
kubectl -n "$DISTRIBUTION_NAMESPACE" rollout status deployment/distribution-proxy  --timeout=3m
echo "==> Waiting for distribution-hosted to be Ready..."
kubectl -n "$DISTRIBUTION_NAMESPACE" rollout status deployment/distribution-hosted --timeout=3m

echo "==> Done."
echo "    Pull through cgr.dev: localhost:5050/${CHAINGUARD_ORG}/<image>:<tag>"
echo "    Push hosted target:   localhost:5051/<image>:<tag>"
echo "    cgr.dev proxy:        cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
