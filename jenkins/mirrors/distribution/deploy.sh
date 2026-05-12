#!/usr/bin/env bash
# Deploy distribution/distribution into the shared kind cluster as both a
# pull-through proxy (port 5050) and a separate hosted registry (port 5051).
#
# Authenticates to cgr.dev one of two ways, selected by AUTH_MODE:
#   proxy       (default): distribution-proxy's `proxy.remoteurl` points at
#                          the in-cluster cgr-oidc-proxy. The proxy holds a
#                          projected ServiceAccount JWT, exchanges it at
#                          Chainguard's STS for a short-lived registry
#                          bearer, and injects it on every outbound request
#                          to cgr.dev. No long-lived pull token on disk.
#   pull-token            distribution-proxy talks to cgr.dev directly using
#                          a chainctl-minted pull token (cached under
#                          mirrors/_common/.pull-tokens/). A `regcred` Secret
#                          in mirror-distribution lets kubelet pull the
#                          distribution image itself.
#
# Required env vars:
#   CHAINGUARD_ORG     Chainguard org being proxied (e.g. 'your-org.example.com')
#
# Optional:
#   AUTH_MODE          'proxy' (default) or 'pull-token'. Normally set by setup.sh.
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

# Pull in the shared bootstrap library — kind cluster, JWKS capture, and
# either the cgr-oidc-proxy stack (AUTH_MODE=proxy) or a chainctl pull-token
# regcred Secret (AUTH_MODE=pull-token). COMMON_DIR auto-derives from
# BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (auth-mode-dependent) --------------------
common::bootstrap_all

# ---- Stage 2: distribution-specific (proxy + hosted Deployments) --------

# Build the proxy `proxy:` config.yml block and the pod-level
# imagePullSecrets block based on AUTH_MODE. In proxy mode the in-cluster
# cgr-oidc-proxy injects the bearer, so distribution-proxy talks to it
# over plain HTTP with no credentials. In pull-token mode distribution
# itself authenticates to cgr.dev using the regcred-derived username +
# long-lived JWT, and the hosted/proxy pods reference regcred so kubelet
# can pull the distribution image directly (the kind cluster has no
# containerd mirror redirect in this mode).
case "${AUTH_MODE:-proxy}" in
  pull-token)
    PROXY_BLOCK=$'    proxy:\n      remoteurl: https://cgr.dev\n      username: '"$PULL_USER"$'\n      password: '"$PULL_PASS"
    IMAGE_PULL_SECRETS_BLOCK=$'      imagePullSecrets:\n        - name: regcred'
    ;;
  *)
    PROXY_BLOCK=$'    proxy:\n      remoteurl: http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000'
    IMAGE_PULL_SECRETS_BLOCK='      # (AUTH_MODE=proxy: kubelet uses the containerd cgr.dev mirror)'
    ;;
esac
export PROXY_BLOCK IMAGE_PULL_SECRETS_BLOCK

echo "==> Rendering distribution manifests for AUTH_MODE=${AUTH_MODE:-proxy} with DISTRIBUTION_IMAGE=${DISTRIBUTION_IMAGE}..."
envsubst '${PROXY_BLOCK}' \
  < k8s/proxy/configmap.yaml.template > k8s/proxy/configmap.yaml
envsubst '${DISTRIBUTION_IMAGE} ${IMAGE_PULL_SECRETS_BLOCK}' \
  < k8s/proxy/deployment.yaml.template  > k8s/proxy/deployment.yaml
envsubst '${DISTRIBUTION_IMAGE} ${IMAGE_PULL_SECRETS_BLOCK}' \
  < k8s/hosted/deployment.yaml.template > k8s/hosted/deployment.yaml

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
if [[ "${AUTH_MODE:-proxy}" == "pull-token" ]]; then
  echo "    cgr.dev auth:         chainctl pull token (regcred Secret in ${DISTRIBUTION_NAMESPACE})"
else
  echo "    cgr.dev proxy:        cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
fi
