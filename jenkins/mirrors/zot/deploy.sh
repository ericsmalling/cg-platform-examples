#!/usr/bin/env bash
# Deploy a project-zot registry into the shared kind cluster, configured as
# both:
#   * a pull-through cache for cgr.dev/${CHAINGUARD_ORG}/* via zot's sync
#     extension. Source depends on $AUTH_MODE:
#       proxy       — sync points at the in-cluster cgr-oidc-proxy, which
#                     holds a short-lived Chainguard bearer derived from a
#                     projected k8s SA JWT (no long-lived pull tokens).
#       pull-token  — sync points directly at https://cgr.dev using a
#                     long-lived chainctl pull token mounted from a Secret.
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
#   AUTH_MODE          'proxy' (default) or 'pull-token'. Set by setup.sh.
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

# ---- Stage 1: shared bootstrap (kind + auth mode setup) -----------------
common::bootstrap_all

# ---- Stage 2: zot-specific manifests ------------------------------------

AUTH_MODE="${AUTH_MODE:-proxy}"

case "$AUTH_MODE" in
  proxy)
    SYNC_URL="http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000"
    SYNC_TLS_VERIFY="false"
    SYNC_CREDENTIALS_FILE_BLOCK=""
    ;;
  pull-token)
    SYNC_URL="https://cgr.dev"
    SYNC_TLS_VERIFY="true"
    SYNC_CREDENTIALS_FILE_BLOCK='"credentialsFile": "/etc/zot/creds.json",
              '
    # zot's sync credentialsFile is a JSON map keyed by registry URL.
    # Re-applied (apply-with-dry-run-merge) so re-runs pick up a rotated token.
    creds_json="$(python3 -c '
import json, os, sys
print(json.dumps({os.environ["SYNC_URL"]: {"username": os.environ["PULL_USER"], "password": os.environ["PULL_PASS"]}}))
' SYNC_URL="$SYNC_URL")"
    SYNC_URL="$SYNC_URL" PULL_USER="$PULL_USER" PULL_PASS="$PULL_PASS" \
      kubectl -n "$ZOT_NAMESPACE" create secret generic zot-sync-creds \
      --from-literal=creds.json="$creds_json" \
      --dry-run=client -o yaml | kubectl apply -f -
    ;;
  *)
    echo "ERROR: unknown AUTH_MODE='$AUTH_MODE' (expected: proxy | pull-token)" >&2
    exit 1
    ;;
esac

echo "==> Rendering zot ConfigMap (AUTH_MODE=$AUTH_MODE, CHAINGUARD_ORG=$CHAINGUARD_ORG)..."
export CHAINGUARD_ORG SYNC_URL SYNC_TLS_VERIFY SYNC_CREDENTIALS_FILE_BLOCK
envsubst '${CHAINGUARD_ORG} ${SYNC_URL} ${SYNC_TLS_VERIFY} ${SYNC_CREDENTIALS_FILE_BLOCK}' \
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
if [[ "$AUTH_MODE" == "proxy" ]]; then
  echo "    cgr.dev proxy:         cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
else
  echo "    cgr.dev upstream:      https://cgr.dev (chainctl pull token via zot-sync-creds Secret)"
fi
