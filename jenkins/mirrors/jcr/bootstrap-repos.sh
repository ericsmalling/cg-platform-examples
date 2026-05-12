#!/usr/bin/env bash
# Bootstrap JFrog Container Registry (JCR) Docker repos via the REST API.
#
# Runs after `kubectl rollout status deployment/jcr` returns. JCR's startup
# probe gates the rollout, so by the time we get here the REST API is
# reachable. We port-forward to the JCR Service for the duration of this
# script (NodePort 30082 → host 8082 also works, but a port-forward is
# robust against the kind extraPortMapping not being wired yet on a
# brand-new cluster, and against the user already having something on
# host:8082).
#
# Steps:
#   1. Port-forward to the JCR Service.
#   2. Wait for /artifactory/api/system/ping to answer 200 OK.
#   3. Confirm admin/password works (JCR CE has no REST password rotation,
#      so we keep the bundled default) and persist it for cgLogin to read.
#   4. Accept the JCR EULA via /api/jcr/eula/accept — without this, every
#      `/api/docker/<repo>/v2/` request answers 503 'you must accept the
#      EULA first' and Docker pulls fail before they reach a manifest.
#   5. PATCH /artifactory/api/system/configuration with a YAML payload
#      that declares all three Docker repos at once:
#        - cgr-proxy     (remote → cgr-oidc-proxy)
#        - library       (local push target)
#        - library-group (virtual aggregating cgr-proxy + library)
#      PATCH is the only repo-create endpoint CE exposes — the per-repo
#      PUT /api/repositories/{key} is gated behind Artifactory Pro.
#   6. Verify the three repos appear in /api/repositories.
#
# PATCH is idempotent: re-running merges the same YAML, leaving repos in
# the same end state. So is the EULA accept call.
set -euo pipefail

JCR_NAMESPACE="${JCR_NAMESPACE:-mirror-jcr}"
JCR_SERVICE="${JCR_SERVICE:-jcr}"
JCR_LOCAL_PORT="${JCR_LOCAL_PORT:-18082}"
JCR_BASE_URL="http://127.0.0.1:${JCR_LOCAL_PORT}/artifactory"

DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PASSWORD="password"
NEW_ADMIN_PASSWORD="${JCR_ADMIN_PASSWORD:-admin123}"

SECRETS_DIR="${SECRETS_DIR:-/tmp/cgjenkins-home/.secrets/jcr}"
PASSWORD_FILE="${SECRETS_DIR}/admin.password"

CGR_OIDC_PROXY_URL="${CGR_OIDC_PROXY_URL:-http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000}"

AUTH_MODE="${AUTH_MODE:-proxy}"
PULL_USER="${PULL_USER:-}"
PULL_PASS="${PULL_PASS:-}"
CHAINGUARD_ORG="${CHAINGUARD_ORG:-}"

if [[ "$AUTH_MODE" == "pull-token" ]]; then
  : "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set in pull-token mode}"
  : "${PULL_USER:?PULL_USER must be set in pull-token mode}"
  : "${PULL_PASS:?PULL_PASS must be set in pull-token mode}"
fi

# ---- Port-forward to the JCR Service for the duration of this script ----
echo "==> Starting kubectl port-forward to JCR (svc/${JCR_SERVICE} :8082 → 127.0.0.1:${JCR_LOCAL_PORT})..."
kubectl -n "$JCR_NAMESPACE" port-forward "svc/${JCR_SERVICE}" "${JCR_LOCAL_PORT}:8082" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Give the port-forward a moment to establish.
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "${JCR_BASE_URL}/api/system/ping" 2>/dev/null; then
    break
  fi
  if (( i == 30 )); then
    echo "ERROR: JCR /artifactory/api/system/ping did not respond within 60s of port-forward start." >&2
    exit 1
  fi
  sleep 2
done

echo "==> JCR API reachable."

# ---- Determine the current admin password ------------------------------
# If we've already run before, NEW_ADMIN_PASSWORD is already in effect.
# JCR Community Edition's REST endpoints for changing the admin password
# are gated behind Artifactory Pro (the v1 changePassword endpoint returns
# "available only in Artifactory Pro", and the Access v2 password APIs
# require bearer-token auth that CE doesn't issue without Pro features).
# So we leave the bundled default `admin/password` in place for the demo.
# Probe to confirm the default still works.
if ! curl -fsS -u "${DEFAULT_ADMIN_USER}:${DEFAULT_ADMIN_PASSWORD}" \
     -o /dev/null "${JCR_BASE_URL}/api/repositories" 2>/dev/null; then
  echo "ERROR: Could not authenticate to JCR as ${DEFAULT_ADMIN_USER}/${DEFAULT_ADMIN_PASSWORD}." >&2
  echo "       JCR Community Edition keeps the default password — if you've changed it" >&2
  echo "       manually, set JCR_ADMIN_PASSWORD env to the current admin password." >&2
  exit 1
fi
CURRENT_PASSWORD="${JCR_ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASSWORD}"
echo "==> Using admin/${CURRENT_PASSWORD} (CE password rotation requires Artifactory Pro)."

# ---- Persist admin password for cgLogin / demo consumers ---------------
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
printf '%s' "$CURRENT_PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"
echo "==> Wrote admin password to ${PASSWORD_FILE} (mode 600)."

AUTH=( -u "${DEFAULT_ADMIN_USER}:${CURRENT_PASSWORD}" )

# ---- Accept the EULA ----------------------------------------------------
# Without this, every Docker request to /api/docker/<repo>/v2/ answers
# 503 "you must accept the EULA first" and pulls fail before they ever
# resolve a manifest. The endpoint accepts an empty body and is
# idempotent (200 OK even if already accepted).
echo "==> Accepting the JCR EULA..."
curl -fsS "${AUTH[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -o /dev/null \
  "${JCR_BASE_URL}/api/jcr/eula/accept"

# ---- Repository creation via the YAML config PATCH endpoint -------------
# JCR Community Edition gates the per-repo /api/repositories/{key} CRUD
# endpoints behind Artifactory Pro (they answer 400 "available only in
# Artifactory Pro"). The system-wide /api/system/configuration PATCH
# endpoint with a YAML body, however, is open in CE and creates remote,
# local, and virtual repos in a single call. PATCH is idempotent:
# re-running merges the same YAML in place.
echo "==> Creating Docker repos via PATCH /api/system/configuration (auth mode: ${AUTH_MODE})..."
if [[ "$AUTH_MODE" == "pull-token" ]]; then
  CGR_REMOTE_URL="https://cgr.dev/${CHAINGUARD_ORG}"
  PATCH_BODY="$(cat <<EOF
remoteRepositories:
  cgr-proxy:
    type: docker
    url: "${CGR_REMOTE_URL}"
    username: "${PULL_USER}"
    password: "${PULL_PASS}"
localRepositories:
  library:
    type: docker
    dockerApiVersion: V2
virtualRepositories:
  library-group:
    type: docker
    repositories:
      - cgr-proxy
      - library
    defaultDeploymentRepo: library
EOF
)"
else
  PATCH_BODY="$(cat <<EOF
remoteRepositories:
  cgr-proxy:
    type: docker
    url: ${CGR_OIDC_PROXY_URL}
localRepositories:
  library:
    type: docker
    dockerApiVersion: V2
virtualRepositories:
  library-group:
    type: docker
    repositories:
      - cgr-proxy
      - library
    defaultDeploymentRepo: library
EOF
)"
fi

curl -fsS "${AUTH[@]}" -X PATCH \
  -H 'Content-Type: application/yaml' \
  --data "$PATCH_BODY" \
  "${JCR_BASE_URL}/api/system/configuration"
echo

# ---- Verify ------------------------------------------------------------
# The Pro-only per-repo GET is also blocked, so list everything and
# string-check. /api/repositories itself is open on CE.
echo "==> Verifying repos..."
REPOS_JSON="$(curl -fsS "${AUTH[@]}" "${JCR_BASE_URL}/api/repositories")"
for key in cgr-proxy library library-group; do
  if ! printf '%s' "$REPOS_JSON" | grep -q "\"key\" *: *\"${key}\""; then
    echo "ERROR: expected repo '${key}' not present after PATCH. JCR response:" >&2
    printf '%s\n' "$REPOS_JSON" >&2
    exit 1
  fi
  echo "    ✓ ${key}"
done
echo "==> All Docker repos in place."
