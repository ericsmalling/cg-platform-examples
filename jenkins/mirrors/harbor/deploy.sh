#!/usr/bin/env bash
# Deploy a Harbor instance into a local kind cluster, configured to proxy
# cgr.dev/${CHAINGUARD_ORG}/* via a public Harbor project named "cgr-proxy".
# Adapted from chainguard-demo/cs-workshop/.../harbor/deploy-harbor.sh — same
# Helm + ingress-nginx + Terraform machinery, but driven by env vars instead
# of interactive prompts so setup.sh can call it non-interactively.
#
# Pull-token model (replaced): the previous version of this script created
# a 30-day Chainguard pull token and stuffed it into a kubernetes
# dockerconfigjson Secret (`regcred`) in the harbor and ingress-nginx
# namespaces, plus into Harbor's RegistryEndpoint as basic auth. That has
# been replaced by an in-cluster `cgr-oidc-proxy` Deployment that holds a
# projected k8s ServiceAccount token, exchanges it at Chainguard's STS for
# a short-lived registry bearer, and injects it on outbound requests.
# kubelet reaches the proxy via a containerd registry mirror configured in
# mirrors/_common/kind/config.yaml; Harbor reaches it via the cluster
# Service. The proxy runs in its own `cgr-oidc-proxy` namespace and is
# shared with any other mirror tool the demo can stand up.
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org to proxy (e.g. 'chainguard' or 'your-org.example.com')
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-mirrors
#
# Idempotent: re-running re-applies the manifests + Helm values + Terraform.
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"

# Tools used here in addition to those required by the shared bootstrap.
for tool in helm curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH" >&2
    exit 1
  fi
done

# Harbor's namespace under the new layout: each mirror tool has its own
# `mirror-<name>` namespace. The shared cgr-oidc-proxy ns is created by
# the bootstrap.
HARBOR_NAMESPACE="mirror-harbor"
export MIRROR_NAMESPACE="$HARBOR_NAMESPACE"
export REGISTRY_URL="cgr.dev/${CHAINGUARD_ORG}"

# Pull in the shared bootstrap library — kind cluster, JWKS capture,
# chainguard_identity (terraform stage 1), proxy ConfigMap, proxy build +
# load + deploy. COMMON_DIR auto-derives from BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + cgr-oidc-proxy + identity) -------
common::require_tools
common::ensure_kind_cluster
common::ensure_namespaces       # creates cgr-oidc-proxy + ingress-nginx + mirror-harbor
common::capture_jwks
PROXY_UIDP="$(common::terraform_identity)"
common::ensure_proxy_configmap "$PROXY_UIDP"
common::build_and_load_proxy
common::deploy_proxy            # waits for the proxy to be Ready

# ---- Stage 2: Harbor-specific (ingress-nginx + Helm + Harbor terraform) -

echo "==> Rendering manifests with REGISTRY_URL=${REGISTRY_URL}..."
envsubst < cg/manifests/deploy-ingress-nginx.template > cg/manifests/deploy-ingress-nginx.yaml
envsubst < cg/helm/values.template               > cg/helm/values.yaml

echo "==> Deploying ingress-nginx..."
# ingress-nginx pulls cgr.dev images via the containerd mirror, so it must
# come *after* the proxy is up (above).
kubectl apply -f cg/manifests/deploy-ingress-nginx.yaml
kubectl wait --for=condition=Ready -n ingress-nginx pod \
  --selector=app.kubernetes.io/name=ingress-nginx \
  --selector=app.kubernetes.io/component=controller \
  --timeout=3m

echo "==> Installing/upgrading Harbor via Helm..."
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null
helm upgrade --install harbor harbor/harbor -n "$HARBOR_NAMESPACE" -f cg/helm/values.yaml --wait --timeout=10m

echo "==> Waiting for Harbor's web ingress to respond..."
# -k: the chart-issued cert is self-signed; we just need to know the
# endpoint is alive, not validate trust. See values.template for why we
# can't run plain HTTP (Harbor #22010).
for i in $(seq 1 60); do
  if curl -fsSk -o /dev/null https://localhost/api/v2.0/health 2>/dev/null; then
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Harbor /api/v2.0/health did not respond at https://localhost/ within 2 minutes." >&2
    exit 1
  fi
  sleep 2
done

echo "==> Configuring Harbor with Terraform (cgr.dev proxy registry + cgr-proxy project; stage 2)..."
( cd terraform
  terraform init -input=false -upgrade
  terraform apply -input=false -auto-approve
)

echo "==> Done."
echo "    Harbor UI:        https://localhost/harbor (admin / Harbor12345; click through cert warning)"
echo "    Proxy cache URL:  localhost/cgr-proxy/${CHAINGUARD_ORG}/<image>:<tag>"
echo "    Push project:     localhost/library/<image>:<tag>"
echo "    cgr.dev proxy:    cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
