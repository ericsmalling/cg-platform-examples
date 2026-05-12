#!/usr/bin/env bash
# Deploy a Harbor instance into a local kind cluster, configured to proxy
# cgr.dev/${CHAINGUARD_ORG}/* via a public Harbor project named "cgr-proxy".
# Adapted from chainguard-demo/cs-workshop/.../harbor/deploy-harbor.sh — same
# Helm + ingress-nginx + Terraform machinery, but driven by env vars instead
# of interactive prompts so setup.sh can call it non-interactively.
#
# Two auth modes (selected by $AUTH_MODE, set by setup.sh):
#   proxy (default) — bootstrap deploys cgr-oidc-proxy in-cluster; Harbor
#       talks to it via the cluster Service with empty creds, and the proxy
#       injects a short-lived OIDC-derived Chainguard bearer. kubelet pulls
#       cgr.dev images via the containerd registry mirror configured in
#       mirrors/_common/kind/config.yaml. No long-lived pull tokens.
#   pull-token — bootstrap mints a chainctl pull token, creates a `regcred`
#       dockerconfigjson Secret in $MIRROR_NAMESPACE, and exports
#       $PULL_USER/$PULL_PASS. The cgr-oidc-proxy is NOT deployed and the
#       kind cluster has no containerd mirror; Harbor talks to cgr.dev
#       directly with the pull token, and we copy regcred into the
#       ingress-nginx namespace so kubelet can pull the ingress controller
#       images.
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org to proxy (e.g. 'chainguard' or 'your-org.example.com')
#
# Optional:
#   AUTH_MODE          'proxy' (default) or 'pull-token'
#   PULL_TOKEN_TTL     chainctl duration; required when AUTH_MODE=pull-token
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
# chainguard_identity + proxy build/deploy (proxy mode) or pull-token mint
# + regcred Secret (pull-token mode). COMMON_DIR auto-derives from
# BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + auth-mode-specific setup) --------
common::bootstrap_all

# In pull-token mode the bootstrap created `regcred` only in
# $MIRROR_NAMESPACE (mirror-harbor). Copy it into ingress-nginx too: the
# kind cluster has no containerd cgr.dev mirror, so kubelet needs the
# Secret in the same namespace as the Pod to pull the controller +
# webhook-certgen images.
AUTH_MODE="${AUTH_MODE:-proxy}"
if [[ "$AUTH_MODE" == "pull-token" ]]; then
  echo "==> Copying regcred Secret into ingress-nginx namespace..."
  kubectl get secret regcred -n "$HARBOR_NAMESPACE" -o json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d["metadata"]={"name":"regcred","namespace":"ingress-nginx"}; json.dump(d,sys.stdout)' \
    | kubectl apply -f -
fi

# ---- Stage 2: Harbor-specific (ingress-nginx + Helm + Harbor terraform) -

# Only inject `imagePullSecrets: [{name: regcred}]` into the ingress-nginx
# Deployment + Jobs when the Secret will actually exist. In proxy mode the
# block is empty (containerd mirror handles the pull).
if [[ "$AUTH_MODE" == "pull-token" ]]; then
  export IMAGE_PULL_SECRETS_BLOCK=$'      imagePullSecrets:\n      - name: regcred'
else
  export IMAGE_PULL_SECRETS_BLOCK=""
fi

echo "==> Rendering manifests with REGISTRY_URL=${REGISTRY_URL}..."
envsubst < cg/manifests/deploy-ingress-nginx.template > cg/manifests/deploy-ingress-nginx.yaml
envsubst < cg/helm/values.template               > cg/helm/values.yaml

echo "==> Deploying ingress-nginx..."
# In proxy mode, ingress-nginx pulls cgr.dev images via the containerd
# mirror, so it must come *after* the proxy is up (above). In pull-token
# mode, kubelet uses the regcred Secret we just copied into ingress-nginx.
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

echo "==> Configuring Harbor with Terraform (cgr.dev upstream registry + cgr-proxy project; stage 2)..."
# In pull-token mode, point Harbor at cgr.dev directly with the minted
# token as basic auth. In proxy mode, the variable defaults (in main.tf)
# point at the in-cluster cgr-oidc-proxy with empty creds.
( cd terraform
  terraform init -input=false -upgrade
  if [[ "$AUTH_MODE" == "pull-token" ]]; then
    terraform apply -input=false -auto-approve \
      -var "endpoint_url=https://cgr.dev" \
      -var "access_id=${PULL_USER}" \
      -var "access_secret=${PULL_PASS}"
  else
    terraform apply -input=false -auto-approve
  fi
)

echo "==> Done."
echo "    Harbor UI:        https://localhost/harbor (admin / Harbor12345; click through cert warning)"
echo "    Proxy cache URL:  localhost/cgr-proxy/${CHAINGUARD_ORG}/<image>:<tag>"
echo "    Push project:     localhost/library/<image>:<tag>"
if [[ "$AUTH_MODE" == "pull-token" ]]; then
  echo "    cgr.dev upstream: https://cgr.dev (chainctl pull token, TTL=${PULL_TOKEN_TTL:-?})"
else
  echo "    cgr.dev proxy:    cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
fi
