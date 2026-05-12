#!/usr/bin/env bash
# Deploy Sonatype Nexus Repository 3 Community Edition into the shared kind
# cluster as an OCI mirror tool. Provides two docker repositories:
#   - cgr-proxy : docker proxy of the in-cluster cgr-oidc-proxy (which
#                 fronts cgr.dev/${CHAINGUARD_ORG}/* with OIDC-derived
#                 short-lived bearers — no long-lived pull tokens).
#                 Exposed on host port 5053. Pull-only.
#   - library   : docker hosted, the push target for built images.
#                 Exposed on host port 5060. CE doesn't support writable
#                 group repos so pulls and pushes use separate connectors.
#
# Required env vars:
#   CHAINGUARD_ORG  Chainguard org being proxied via cgr-oidc-proxy.
#
# Optional:
#   KIND_CLUSTER_NAME  default: jenkins-mirrors
#   NEXUS_ADMIN_PASS   default: admin123 (>=8 chars; Nexus requires it).
#
# Idempotent: re-applies manifests + re-runs the REST bootstrap.
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"

# Tools used here in addition to those required by the shared bootstrap.
for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH" >&2
    exit 1
  fi
done

export MIRROR_NAMESPACE="mirror-nexus-ce"

# Pull in the shared bootstrap library — kind cluster, JWKS capture,
# chainguard_identity (terraform stage 1), proxy ConfigMap, proxy build +
# load + deploy. COMMON_DIR auto-derives from BASH_SOURCE inside the lib.
# shellcheck source=../_common/bootstrap.sh
source "$SCRIPT_DIR/../_common/bootstrap.sh"

# ---- Stage 1: shared bootstrap (kind + cgr-oidc-proxy + identity) -------
common::bootstrap_all

# ---- Stage 2: Nexus CE manifests ----------------------------------------
echo "==> Applying Nexus CE manifests..."
kubectl apply -f k8s/

echo "==> Waiting for Nexus rollout (slow start: ~2-3 minutes)..."
kubectl -n "$MIRROR_NAMESPACE" rollout status deployment/nexus-ce --timeout=10m

# ---- Stage 3: REST bootstrap (admin pw rotation + repo create) ---------
# AUTH_MODE/PULL_USER/PULL_PASS/CHAINGUARD_ORG drive whether the cgr-proxy
# repo is configured to talk to the in-cluster cgr-oidc-proxy (proxy mode)
# or directly to cgr.dev/<org> with a pull-token basic-auth (pull-token mode).
echo "==> Bootstrapping Nexus repositories via REST..."
NEXUS_NAMESPACE="$MIRROR_NAMESPACE" \
AUTH_MODE="${AUTH_MODE:-proxy}" \
PULL_USER="${PULL_USER:-}" \
PULL_PASS="${PULL_PASS:-}" \
PULL_TOKEN_TTL="${PULL_TOKEN_TTL:-}" \
CHAINGUARD_ORG="$CHAINGUARD_ORG" \
  "$SCRIPT_DIR/bootstrap-repos.sh"

echo "==> Done."
echo "    Nexus UI:           http://localhost:8081 (admin / ${NEXUS_ADMIN_PASS:-admin123})"
echo "    Pull through cgr.dev: localhost:5053/<image>:<tag>      (cgr-proxy)"
echo "    Push hosted target:   localhost:5060/<image>:<tag>      (library)"
echo "    Admin password:     /tmp/cgjenkins-home/.secrets/nexus-ce/admin.password"
if [[ "${AUTH_MODE:-proxy}" == "pull-token" ]]; then
  echo "    cgr.dev upstream:   https://cgr.dev/${CHAINGUARD_ORG} (basic-auth via chainctl pull token)"
else
  echo "    cgr.dev proxy:      cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000 (no long-lived pull token; OIDC-derived bearer auto-rotates)"
fi
