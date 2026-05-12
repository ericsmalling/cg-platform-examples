#!/usr/bin/env bash
# Bootstrap Nexus CE's docker repositories via the REST API.
#
# Strategy: rather than build a tools image with curl baked in to run as an
# in-cluster Job, this script runs from the host and reaches Nexus via a
# transient `kubectl port-forward`. That keeps the dependency surface small
# (curl + jq + kubectl are already required by the demo) and avoids an extra
# Chainguard-image rebuild every time we tweak the bootstrap.
#
# Steps:
#   1. Read /nexus-data/admin.password (the first-run bootstrap password Nexus
#      writes on initial startup) via `kubectl exec`. If it's already gone,
#      a previous run completed and we use the stable demo password.
#   2. Set the permanent admin password to the stable demo value
#      (admin123 — Nexus rejects anything shorter than 8 characters).
#   3. Persist that password to /tmp/cgjenkins-home/.secrets/nexus-ce/admin.password
#      so cgLogin can pick it up.
#   4. Enable the Docker Bearer Token realm.
#   5. Create the docker proxy / hosted / group repos (idempotent).
#
# Required env vars:
#   CHAINGUARD_ORG  Used to log the proxy URL but not interpolated into Nexus
#                    config; the cgr-oidc-proxy itself rewrites paths.
# Optional:
#   NEXUS_ADMIN_PASS  The permanent admin password (default: admin123 —
#                     Nexus requires >= 8 characters).
#
set -euo pipefail

NEXUS_NAMESPACE="${NEXUS_NAMESPACE:-mirror-nexus-ce}"
NEXUS_ADMIN_PASS="${NEXUS_ADMIN_PASS:-admin123}"
SECRETS_DIR="${SECRETS_DIR:-/tmp/cgjenkins-home/.secrets/nexus-ce}"
ADMIN_PASS_FILE="${SECRETS_DIR}/admin.password"
LOCAL_PORT="${LOCAL_PORT:-18081}"
NEXUS_BASE="http://127.0.0.1:${LOCAL_PORT}"

AUTH_MODE="${AUTH_MODE:-proxy}"
PULL_USER="${PULL_USER:-}"
PULL_PASS="${PULL_PASS:-}"
CHAINGUARD_ORG="${CHAINGUARD_ORG:-}"

# Upstream URL for the cgr-proxy docker proxy repo.
#   proxy mode:      in-cluster cgr-oidc-proxy injects an OIDC-derived bearer;
#                    Nexus talks to it anonymously over plain HTTP.
#   pull-token mode: Nexus talks directly to cgr.dev/<org> using a long-lived
#                    pull token configured as basic-auth on the httpClient.
if [[ -z "${CGR_PROXY_URL:-}" ]]; then
  if [[ "$AUTH_MODE" == "pull-token" ]]; then
    if [[ -z "$CHAINGUARD_ORG" ]]; then
      echo "ERROR: CHAINGUARD_ORG must be set when AUTH_MODE=pull-token" >&2
      exit 1
    fi
    CGR_PROXY_URL="https://cgr.dev/${CHAINGUARD_ORG}"
  else
    CGR_PROXY_URL="http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000"
  fi
fi

for tool in kubectl curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH" >&2
    exit 1
  fi
done

POD=""
PORT_FORWARD_PID=""

cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]] && kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> Locating Nexus pod..."
for i in $(seq 1 30); do
  POD="$(kubectl -n "$NEXUS_NAMESPACE" get pod -l app.kubernetes.io/name=nexus-ce \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$POD" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$POD" ]]; then
  echo "ERROR: no Running Nexus pod found in namespace $NEXUS_NAMESPACE" >&2
  exit 1
fi
echo "    pod: $POD"

echo "==> Starting kubectl port-forward to $POD:8081 -> 127.0.0.1:${LOCAL_PORT}..."
kubectl -n "$NEXUS_NAMESPACE" port-forward "pod/$POD" "${LOCAL_PORT}:8081" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for the port-forward to actually accept connections AND for Nexus to
# return a healthy /service/rest/v1/status. Status returns 200 when ready.
echo "==> Waiting for Nexus REST to respond..."
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "${NEXUS_BASE}/service/rest/v1/status" 2>/dev/null; then
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Nexus did not respond at ${NEXUS_BASE} within 2 minutes." >&2
    exit 1
  fi
  sleep 2
done

# ---- Resolve the current admin password ---------------------------------
# First-run path: /nexus-data/admin.password exists; read it.
# Already-bootstrapped path: file is gone; use the stable demo password.
echo "==> Resolving admin credentials..."
BOOTSTRAP_PASS=""
if kubectl -n "$NEXUS_NAMESPACE" exec "$POD" -- test -f /nexus-data/admin.password 2>/dev/null; then
  BOOTSTRAP_PASS="$(kubectl -n "$NEXUS_NAMESPACE" exec "$POD" -- cat /nexus-data/admin.password)"
  BOOTSTRAP_PASS="${BOOTSTRAP_PASS%$'\n'}"
  echo "    found first-run bootstrap password in /nexus-data/admin.password"
else
  echo "    first-run bootstrap file gone; assuming admin password already rotated."
fi

# Probe whether the stable demo password works. If it does, we already
# rotated in a previous run; skip the rotation step.
ADMIN_PASS=""
http_code="$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${NEXUS_ADMIN_PASS}" \
  "${NEXUS_BASE}/service/rest/v1/status/writable" || true)"
if [[ "$http_code" == "200" ]]; then
  ADMIN_PASS="$NEXUS_ADMIN_PASS"
  echo "    admin/${NEXUS_ADMIN_PASS} already accepted; password rotation already done."
elif [[ -n "$BOOTSTRAP_PASS" ]]; then
  echo "==> Rotating admin password to the demo value..."
  # PUT /service/rest/v1/security/users/admin/change-password takes the new
  # password as raw text/plain (not JSON). Authenticated as admin with the
  # bootstrap password.
  curl -fsS -u "admin:${BOOTSTRAP_PASS}" -X PUT \
    -H 'Content-Type: text/plain' \
    --data "${NEXUS_ADMIN_PASS}" \
    "${NEXUS_BASE}/service/rest/v1/security/users/admin/change-password"
  ADMIN_PASS="$NEXUS_ADMIN_PASS"
else
  echo "ERROR: no bootstrap password and demo password rejected; cannot proceed." >&2
  echo "       (delete the PVC and redeploy, or set NEXUS_ADMIN_PASS to the current admin pw)" >&2
  exit 1
fi

# ---- Persist the admin password for cgLogin -----------------------------
echo "==> Persisting admin password to ${ADMIN_PASS_FILE}..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
umask 077
printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE"
chmod 600 "$ADMIN_PASS_FILE"

# Helpers --------------------------------------------------------------------
auth=( -u "admin:${ADMIN_PASS}" )

# ---- Accept the Community Edition EULA ----------------------------------
# Nexus CE 3.91+ blocks all docker-connector traffic with HTTP 403 until
# the EULA is accepted via REST. We GET the current disclaimer text (which
# changes between releases), then POST it back with accepted=true. The
# disclaimer must match exactly — Nexus rejects any modification.
echo "==> Accepting Nexus CE EULA..."
disclaimer="$(curl -sS "${auth[@]}" "${NEXUS_BASE}/service/rest/v1/system/eula" | jq -r .disclaimer)"
if [[ -z "$disclaimer" || "$disclaimer" == "null" ]]; then
  echo "ERROR: failed to fetch EULA disclaimer text from Nexus." >&2
  exit 1
fi
eula_payload="$(jq -nc --arg d "$disclaimer" '{accepted:true,disclaimer:$d}')"
http="$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" \
  -H 'Content-Type: application/json' \
  -X POST --data "$eula_payload" \
  "${NEXUS_BASE}/service/rest/v1/system/eula" || true)"
if [[ "$http" != "204" && "$http" != "200" ]]; then
  echo "ERROR: POST /service/rest/v1/system/eula returned HTTP $http" >&2
  exit 1
fi

# Tolerate "already exists" responses. Nexus returns 400 with a message body
# containing "already exists" when the resource is a duplicate. POST returns
# 201 on create.
nexus_post_json() {
  local path="$1"
  local body="$2"
  local resp http
  resp="$(mktemp)"
  http="$(curl -sS -o "$resp" -w '%{http_code}' "${auth[@]}" \
    -H 'Content-Type: application/json' \
    -X POST --data "$body" \
    "${NEXUS_BASE}${path}" || true)"
  if [[ "$http" == "201" || "$http" == "204" ]]; then
    rm -f "$resp"
    return 0
  fi
  if [[ "$http" == "400" ]] && grep -qiE 'already exists|in use' "$resp"; then
    echo "    (already exists, skipping: $path)"
    rm -f "$resp"
    return 0
  fi
  echo "ERROR: POST $path returned HTTP $http" >&2
  cat "$resp" >&2
  rm -f "$resp"
  return 1
}

nexus_put_json() {
  local path="$1"
  local body="$2"
  local resp http
  resp="$(mktemp)"
  http="$(curl -sS -o "$resp" -w '%{http_code}' "${auth[@]}" \
    -H 'Content-Type: application/json' \
    -X PUT --data "$body" \
    "${NEXUS_BASE}${path}" || true)"
  if [[ "$http" == "200" || "$http" == "204" ]]; then
    rm -f "$resp"
    return 0
  fi
  echo "ERROR: PUT $path returned HTTP $http" >&2
  cat "$resp" >&2
  rm -f "$resp"
  return 1
}

# ---- Enable the Docker Bearer Token realm -------------------------------
# Without this, `docker login localhost:5053` fails because Nexus has no way
# to issue the bearer token Docker's auth flow expects.
echo "==> Enabling Docker Bearer Token realm..."
realms='["DockerToken","NexusAuthenticatingRealm"]'
nexus_put_json "/service/rest/v1/security/realms/active" "$realms"

# ---- Create cgr-proxy (docker proxy) ------------------------------------
# proxy mode:      remoteUrl is the in-cluster cgr-oidc-proxy; httpClient is
#                  anonymous (the proxy supplies its own OIDC-derived bearer).
# pull-token mode: remoteUrl is cgr.dev/<org>; httpClient.authentication
#                  carries the chainctl pull token as basic-auth credentials.
echo "==> Creating docker proxy repo 'cgr-proxy' (AUTH_MODE=${AUTH_MODE})..."
if [[ "$AUTH_MODE" == "pull-token" ]]; then
  if [[ -z "$PULL_USER" || -z "$PULL_PASS" ]]; then
    echo "ERROR: PULL_USER and PULL_PASS must be set when AUTH_MODE=pull-token" >&2
    exit 1
  fi
  # jq safely escapes the JWT/UIDP values for embedding in JSON.
  proxy_body="$(jq -nc \
    --arg url   "$CGR_PROXY_URL" \
    --arg user  "$PULL_USER" \
    --arg pass  "$PULL_PASS" \
    '{
      name: "cgr-proxy",
      online: true,
      storage: { blobStoreName: "default", strictContentTypeValidation: true },
      proxy:   { remoteUrl: $url, contentMaxAge: 1440, metadataMaxAge: 1440 },
      negativeCache: { enabled: true, timeToLive: 1440 },
      httpClient: {
        blocked: false,
        autoBlock: true,
        authentication: { type: "username", username: $user, password: $pass }
      },
      docker:      { v1Enabled: false, forceBasicAuth: false, httpPort: 5053 },
      dockerProxy: { indexType: "REGISTRY" }
    }')"
else
  proxy_body="$(jq -nc --arg url "$CGR_PROXY_URL" \
    '{
      name: "cgr-proxy",
      online: true,
      storage: { blobStoreName: "default", strictContentTypeValidation: true },
      proxy:   { remoteUrl: $url, contentMaxAge: 1440, metadataMaxAge: 1440 },
      negativeCache: { enabled: true, timeToLive: 1440 },
      httpClient:  { blocked: false, autoBlock: true },
      docker:      { v1Enabled: false, forceBasicAuth: false, httpPort: 5053 },
      dockerProxy: { indexType: "REGISTRY" }
    }')"
fi
nexus_post_json "/service/rest/v1/repositories/docker/proxy" "$proxy_body"

# ---- Create library (docker hosted) -------------------------------------
# Nexus CE does not support writable group repos (writableMember is a Pro
# feature), so library exposes its own docker connector on port 5060 for
# pushes. Pulls go through cgr-proxy on 5053; pushes go to library on 5060.
echo "==> Creating docker hosted repo 'library'..."
hosted_body=$(cat <<'JSON'
{
  "name": "library",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "ALLOW"
  },
  "docker": {
    "v1Enabled": false,
    "forceBasicAuth": true,
    "httpPort": 5060
  }
}
JSON
)
nexus_post_json "/service/rest/v1/repositories/docker/hosted" "$hosted_body"

echo "==> Nexus repository bootstrap complete."
