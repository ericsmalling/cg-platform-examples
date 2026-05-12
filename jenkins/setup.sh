#!/usr/bin/env bash
# Interactive bootstrap. Picks one OCI mirror tool for the demo to use as
# the Chainguard images pull-through cache (and, for tools that support it,
# the push target for built images).
#
# Modes (MIRROR_TOOL stored in .env):
#
#   none         — direct cgr.dev with Jenkins OIDC chainctl per build.
#   harbor       — Harbor 2.x; full pull-through + push project.
#   distribution — distribution/distribution; separate proxy + hosted instances.
#   zot          — project-zot v2.x; single instance with sync extension.
#   nexus-ce     — Sonatype Nexus Repository Community Edition.
#   jcr          — JFrog Container Registry (free non-commercial).
#
# Every mirror choice (anything but 'none') stands up a single shared kind
# cluster, then prompts how the mirror should authenticate to cgr.dev:
#   proxy       — in-cluster cgr-oidc-proxy mints short-lived registry
#                 bearers from a projected ServiceAccount JWT (no long-lived
#                 creds on disk). Stored as AUTH_MODE=proxy in .env.
#   pull-token  — `chainctl auth pull-token create` mints a long-lived
#                 basic-auth pair with a user-chosen TTL (default 168h);
#                 the mirror stores it as static upstream creds. Stored as
#                 AUTH_MODE=pull-token + PULL_TOKEN_TTL=<duration> in .env.
# The `none` mode (direct cgr.dev) uses Jenkins OIDC per-build chainctl
# and isn't affected.
set -euo pipefail

cd "$(dirname "$0")"

# Pick up CHAINGUARD_ORG (and any prior choices) from .env if present.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_OIDC_ISSUER="${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}"

# Prompt for the Chainguard org if .env didn't supply one. The answer gets
# persisted to .env in Phase 1 below, so subsequent re-runs go straight
# through without prompting.
if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
  echo "==> No Chainguard org configured."
  echo "    Examples: 'chainguard' (public catalog) or 'your-org.example.com'."
  while [[ -z "${CHAINGUARD_ORG:-}" ]]; do
    read -rp "    Enter your Chainguard org: " CHAINGUARD_ORG
  done
  echo
fi
ORG="$CHAINGUARD_ORG"
echo "==> Chainguard org: ${ORG}"
echo

# ---- Mirror selection ----------------------------------------------------
#
# Six choices. Re-running setup.sh swaps tools (current state is torn down
# by the chosen tool's deploy.sh on re-apply, since they all share one kind
# cluster name and namespaces are tool-specific).

# Suggest the previously chosen tool as default, if any.
PRIOR_TOOL="${MIRROR_TOOL:-}"
# Backward compat: prior runs of this script wrote HARBOR_ENABLED only.
if [[ -z "$PRIOR_TOOL" && "${HARBOR_ENABLED:-}" == "true" ]]; then
  PRIOR_TOOL="harbor"
fi
[[ -z "$PRIOR_TOOL" ]] && PRIOR_TOOL="none"

echo "==> Pick a pull-through mirror tool:"
echo "    1) none         — direct cgr.dev with Jenkins OIDC (no cluster)"
echo "    2) harbor       — Harbor 2.x"
echo "    3) distribution — distribution/distribution OSS registry"
echo "    4) zot          — project-zot OCI registry"
echo "    5) nexus-ce     — Sonatype Nexus Repository Community Edition"
echo "    6) jcr          — JFrog Container Registry (non-commercial)"
echo
case "$PRIOR_TOOL" in
  none)         DEFAULT_NUM=1 ;;
  harbor)       DEFAULT_NUM=2 ;;
  distribution) DEFAULT_NUM=3 ;;
  zot)          DEFAULT_NUM=4 ;;
  nexus-ce)     DEFAULT_NUM=5 ;;
  jcr)          DEFAULT_NUM=6 ;;
  *)            DEFAULT_NUM=1 ;;
esac

MIRROR_TOOL=""
while [[ -z "$MIRROR_TOOL" ]]; do
  read -rp "    Choose [1-6, default ${DEFAULT_NUM}]: " ans
  ans="${ans:-$DEFAULT_NUM}"
  case "$ans" in
    1) MIRROR_TOOL=none ;;
    2) MIRROR_TOOL=harbor ;;
    3) MIRROR_TOOL=distribution ;;
    4) MIRROR_TOOL=zot ;;
    5) MIRROR_TOOL=nexus-ce ;;
    6) MIRROR_TOOL=jcr ;;
    *) echo "    invalid choice: $ans" ;;
  esac
done
echo "==> Selected: ${MIRROR_TOOL}"
echo

# ---- Auth mode selection -------------------------------------------------
#
# None of the 5 mirror tools natively support OIDC for upstream registry
# pulls — they all only accept a static username/password pair for upstream
# auth. So for any non-`none` mode the demo offers two ways to supply
# Chainguard credentials to the mirror:
#
#   proxy       — deploy the in-cluster cgr-oidc-proxy. It holds a projected
#                 ServiceAccount JWT, exchanges it at Chainguard's STS for a
#                 short-lived registry bearer, and injects it on every
#                 outbound request. No long-lived creds on disk.
#   pull-token  — `chainctl auth pull-token create` mints a long-lived
#                 basic-auth pair (Chainguard identity_id + JWT) with a
#                 user-chosen TTL. The mirror tool stores this as static
#                 upstream creds. Simpler to operate, but the credential
#                 has a fixed lifetime and lives on disk until rotated.
#
# `none` mode (direct cgr.dev) always uses per-build Jenkins OIDC — no proxy,
# no pull token — so the prompt is skipped.

if [[ "$MIRROR_TOOL" == "none" ]]; then
  AUTH_MODE="oidc-direct"
  PULL_TOKEN_TTL=""
else
  PRIOR_AUTH="${AUTH_MODE:-proxy}"
  case "$PRIOR_AUTH" in
    proxy)      DEFAULT_AUTH_NUM=1 ;;
    pull-token) DEFAULT_AUTH_NUM=2 ;;
    *)          DEFAULT_AUTH_NUM=1 ;;
  esac
  echo "==> How should the ${MIRROR_TOOL} mirror authenticate to cgr.dev?"
  echo "    1) proxy       — in-cluster cgr-oidc-proxy (OIDC, no long-lived creds)"
  echo "    2) pull-token  — chainctl-issued long-lived basic auth"
  echo
  AUTH_MODE=""
  while [[ -z "$AUTH_MODE" ]]; do
    read -rp "    Choose [1-2, default ${DEFAULT_AUTH_NUM}]: " ans
    ans="${ans:-$DEFAULT_AUTH_NUM}"
    case "$ans" in
      1) AUTH_MODE=proxy ;;
      2) AUTH_MODE=pull-token ;;
      *) echo "    invalid choice: $ans" ;;
    esac
  done
  echo "==> Auth mode: ${AUTH_MODE}"
  echo

  if [[ "$AUTH_MODE" == "pull-token" ]]; then
    # TTL accepts Go-duration strings (24h, 168h, 720h, ...). chainctl auth
    # pull-token create rejects anything else; we don't try to validate
    # client-side beyond non-emptiness — let chainctl be the source of truth.
    PRIOR_TTL="${PULL_TOKEN_TTL:-168h}"
    read -rp "    Pull-token TTL [default ${PRIOR_TTL}; e.g. 24h, 168h, 720h]: " ans
    PULL_TOKEN_TTL="${ans:-$PRIOR_TTL}"
    echo "==> Pull-token TTL: ${PULL_TOKEN_TTL}"
    echo
  else
    PULL_TOKEN_TTL=""
  fi
fi

# Per-tool URL layout. Pipelines reference $PULL_REGISTRY and $PUSH_REGISTRY;
# whichever tool got picked exposes those URLs on host ports defined in
# mirrors/_common/kind/config.yaml.
case "$MIRROR_TOOL" in
  none)
    PULL_REGISTRY="cgr.dev/${ORG}"
    # Push to user's choice of ttl.sh prefix or other; prompt below.
    NEEDS_PUSH_PROMPT=true
    PUSH_AUTH=oidc
    ;;
  harbor)
    PULL_REGISTRY="localhost/cgr-proxy/${ORG}"
    # Harbor offers a 'library' project for pushes; ask whether to use it
    # or push to ttl.sh anyway (legacy Mode B vs Mode C).
    read -rp "    Push pipeline-built images to Harbor's library project (rather than ttl.sh)? [Y/n]: " ans || true
    ans="${ans:-y}"
    if [[ "$ans" =~ ^[Yy] ]]; then
      PUSH_REGISTRY="localhost/library"
      PUSH_AUTH=harbor-admin
      NEEDS_PUSH_PROMPT=false
    else
      NEEDS_PUSH_PROMPT=true
      PUSH_AUTH=none
    fi
    ;;
  distribution)
    PULL_REGISTRY="localhost:5050/${ORG}"
    PUSH_REGISTRY="localhost:5051"
    PUSH_AUTH=none
    NEEDS_PUSH_PROMPT=false
    ;;
  zot)
    PULL_REGISTRY="localhost:5052"
    PUSH_REGISTRY="localhost:5052/library"
    PUSH_AUTH=none
    NEEDS_PUSH_PROMPT=false
    ;;
  nexus-ce)
    # CE doesn't support writable group repos, so pulls and pushes use
    # separate Docker connectors: cgr-proxy on 5053 (pulls), library on
    # 5060 (pushes).
    PULL_REGISTRY="localhost:5053/${ORG}"
    PUSH_REGISTRY="localhost:5060"
    PUSH_AUTH=nexus-admin
    NEEDS_PUSH_PROMPT=false
    ;;
  jcr)
    PULL_REGISTRY="localhost:5054/cgr-proxy/${ORG}"
    PUSH_REGISTRY="localhost:5054/library"
    PUSH_AUTH=jcr-admin
    NEEDS_PUSH_PROMPT=false
    ;;
esac

if [[ "$NEEDS_PUSH_PROMPT" == "true" ]]; then
  PUSH_REGISTRY_DEFAULT="${PUSH_REGISTRY:-}"
  PUSH_REGISTRY=""
  while [[ -z "$PUSH_REGISTRY" ]]; do
    if [[ -n "$PUSH_REGISTRY_DEFAULT" ]]; then
      read -rp "    Where should pipelines push their built images? [last used: ${PUSH_REGISTRY_DEFAULT}]: " PUSH_REG_INPUT
      PUSH_REGISTRY="${PUSH_REG_INPUT:-$PUSH_REGISTRY_DEFAULT}"
    else
      read -rp "    Where should pipelines push their built images? (e.g. ttl.sh/your-prefix): " PUSH_REGISTRY
    fi
  done
fi

# Backward-compat flag for any code (cgLogin etc.) that still checks it.
if [[ "$MIRROR_TOOL" == "harbor" ]]; then HARBOR_ENABLED=true; else HARBOR_ENABLED=false; fi

echo
echo "==> Mode summary:"
echo "    Mirror tool:   ${MIRROR_TOOL}"
echo "    Auth mode:     ${AUTH_MODE}${PULL_TOKEN_TTL:+ (TTL: ${PULL_TOKEN_TTL})}"
echo "    Pulls from:    ${PULL_REGISTRY}"
echo "    Pushes to:     ${PUSH_REGISTRY}"
echo "    Push auth:     ${PUSH_AUTH}"
echo

# ---- Phase 0: preflight image accessibility check ------------------------
# Probe every image the demo will pull from cgr.dev/$ORG/ before spinning
# anything up. Catches misconfigured org names, missing access grants, and
# stale chainctl sessions early — with a clear list of what's missing —
# instead of letting docker build / kubectl apply fail several minutes in
# with cryptic auth errors. Set SKIP_PREFLIGHT=1 to bypass.

CORE_IMAGES=(
  # Controller build dependencies (Dockerfile.jenkins multi-stage sources).
  jenkins:2-lts-jdk21-dev
  docker-cli:29
  chainctl:latest-dev
  # One-shot tools spawned by pipelines or shared-library helpers.
  cosign:latest-dev
  crane:latest-dev
  # cgImage catalog tags. Tags only — manifest probes resolve the
  # current-tip digest, which is what cgImage's pinned digests track too.
  maven:3-jdk17-dev
  amazon-corretto-jre:17-dev
  maven:3-jdk8-dev
  adoptium-jre:adoptium-openjdk-8-dev
  jdk:openjdk-21-dev
  jre:openjdk-21-dev
  python:3.14-dev
  python:3.14
  python:3.12-dev
  python:3.12
  node:22-dev
  node:22
  node:25-dev
  node:25-slim
)

# Per-mirror image lists. Only Harbor pulls every component from cgr.dev
# (via the in-cluster proxy mirror); distribution, zot, nexus-ce, and jcr
# pull their runtime images from external registries (ghcr.io, sonatype,
# releases-docker.jfrog.io, Docker Hub) which don't need preflight here.
HARBOR_IMAGES=(
  harbor-portal:latest
  harbor-core:latest
  harbor-jobservice:latest
  harbor-registry:latest
  harbor-registryctl:latest
  harbor-trivy-adapter:latest
  harbor-db:latest
  harbor-redis:latest
  ingress-nginx-controller:latest
  kube-webhook-certgen:latest
)

if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  IMAGES_TO_CHECK=("${CORE_IMAGES[@]}")
  case "$MIRROR_TOOL" in
    harbor) IMAGES_TO_CHECK+=("${HARBOR_IMAGES[@]}") ;;
  esac

  echo "==> Preflight: probing ${#IMAGES_TO_CHECK[@]} images at cgr.dev/${ORG}/..."
  # Parallel HEAD-style probes via `docker manifest inspect`. Each subshell
  # writes one line per image (`OK <tag>` or `FAIL <tag>`) — line-atomic on
  # Linux for short writes — to a tempfile that we then iterate in INPUT
  # order so the printed list matches the array above.
  PREFLIGHT_RESULTS=$(mktemp)
  trap 'rm -f "$PREFLIGHT_RESULTS"' EXIT
  printf '%s\n' "${IMAGES_TO_CHECK[@]}" | xargs -P 8 -I {} sh -c '
    if docker manifest inspect "cgr.dev/'"$ORG"'/{}" >/dev/null 2>&1; then
      echo "OK {}"
    else
      echo "FAIL {}"
    fi
  ' >> "$PREFLIGHT_RESULTS" || true

  PF_GREEN=$'\033[32m'
  PF_RED=$'\033[31m'
  PF_RESET=$'\033[0m'
  PF_MISSING=0
  for img in "${IMAGES_TO_CHECK[@]}"; do
    if grep -qx "OK $img" "$PREFLIGHT_RESULTS"; then
      printf '    %s✓%s cgr.dev/%s/%s\n' "$PF_GREEN" "$PF_RESET" "$ORG" "$img"
    else
      printf '    %s✗%s cgr.dev/%s/%s\n' "$PF_RED"   "$PF_RESET" "$ORG" "$img"
      PF_MISSING=$((PF_MISSING + 1))
    fi
  done
  rm -f "$PREFLIGHT_RESULTS"
  trap - EXIT

  if (( PF_MISSING > 0 )); then
    echo >&2
    echo "ERROR: ${PF_MISSING} image(s) not accessible at cgr.dev/${ORG}/." >&2
    echo "Possible causes:" >&2
    echo "  - You're not authenticated to cgr.dev. Try:" >&2
    echo "      chainctl auth login" >&2
    echo "      chainctl auth configure-docker" >&2
    echo "  - Your org doesn't have access to these images yet — request" >&2
    echo "    them at https://console.chainguard.dev/ or via Chainguard support." >&2
    echo "  - CHAINGUARD_ORG is wrong (currently '${ORG}'). Edit .env or unset" >&2
    echo "    the variable to be re-prompted." >&2
    echo >&2
    echo "Bypass with SKIP_PREFLIGHT=1 ./setup.sh if you know what you're doing." >&2
    echo "Aborting setup." >&2
    exit 1
  fi
  echo "    All ${#IMAGES_TO_CHECK[@]} images accessible."
  echo
else
  echo "==> Preflight: SKIP_PREFLIGHT=1 set, skipping image accessibility check."
  echo
fi

# ---- Phase 1a: ensure cosign keypair exists -----------------------------
COSIGN_DIR=/tmp/cgjenkins-home/.secrets
echo "==> Ensuring cosign keypair is present in ${COSIGN_DIR}/..."
mkdir -p "$COSIGN_DIR"
if [[ ! -f "$COSIGN_DIR/cosign.key" ]]; then
  echo "    Generating new cosign keypair..."
  GEN_COSIGN_PASSWORD="$(openssl rand -base64 24)"
  printf '%s' "$GEN_COSIGN_PASSWORD" > "$COSIGN_DIR/cosign.password"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e "COSIGN_PASSWORD=$GEN_COSIGN_PASSWORD" \
    -v "$COSIGN_DIR:/work" \
    -w /work \
    --entrypoint=/usr/bin/cosign \
    "cgr.dev/${ORG}/cosign:latest-dev" \
    generate-key-pair
  chmod 644 "$COSIGN_DIR"/cosign.key "$COSIGN_DIR"/cosign.pub "$COSIGN_DIR"/cosign.password
  unset GEN_COSIGN_PASSWORD
  echo "    Keypair written to ${COSIGN_DIR}/cosign.{key,pub,password}"
else
  echo "    Reusing existing keypair in ${COSIGN_DIR}/cosign.{key,pub,password}"
fi
export COSIGN_PASSWORD="$(cat "$COSIGN_DIR/cosign.password")"

# ---- Phase 1: persist mode flags to .env --------------------------------

echo "==> Writing mode flags to .env..."
[[ -f .env ]] || cp .env.example .env
update_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}
update_env CHAINGUARD_ORG  "$ORG"
update_env MIRROR_TOOL     "$MIRROR_TOOL"
update_env HARBOR_ENABLED  "$HARBOR_ENABLED"
update_env PULL_REGISTRY   "$PULL_REGISTRY"
update_env PUSH_REGISTRY   "$PUSH_REGISTRY"
update_env PUSH_AUTH       "$PUSH_AUTH"
update_env AUTH_MODE       "$AUTH_MODE"
update_env PULL_TOKEN_TTL  "$PULL_TOKEN_TTL"

# ---- Phase 2: (re)create Jenkins ----------------------------------------

echo "==> Bringing up Jenkins (force-recreate to pick up new env)..."
docker compose up -d --build --force-recreate jenkins
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$JENKINS_URL/login" 2>/dev/null; then break; fi
  if (( i == 60 )); then
    echo "ERROR: Jenkins did not respond at $JENKINS_URL/login within 2 minutes." >&2
    exit 1
  fi
  sleep 2
done
echo "==> Jenkins is up at $JENKINS_URL"

# ---- Phase 3: mirror-specific bootstrap ---------------------------------

if [[ "$MIRROR_TOOL" == "none" ]]; then
  echo "==> Direct-cgr.dev mode — bootstrapping the OIDC assumed identity..."
  JWKS_FILE="iac/jenkins-jwks.json"
  mkdir -p iac
  curl -fsS "$JENKINS_URL/oidc/jwks" > "$JWKS_FILE"
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JWKS_FILE" >/dev/null 2>&1; then
    echo "ERROR: $JWKS_FILE is not valid JSON. Got:" >&2
    cat "$JWKS_FILE" >&2
    exit 1
  fi
  echo "    Fetched $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("keys",[])))' "$JWKS_FILE") signing key(s)."
  ( cd iac
    terraform init -input=false -upgrade
    terraform apply -input=false -auto-approve \
      -var="chainguard_group_name=${ORG}" \
      -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER}"
  )
  UIDP=$(cd iac && terraform output -raw identity_uidp)
  if [[ -z "$UIDP" ]]; then
    echo "ERROR: terraform output identity_uidp was empty." >&2
    exit 1
  fi
  echo "    Created identity: ${UIDP}"
  printf '%s\n' "$UIDP" > shared-libraries/cg-images/IDENTITY
else
  if [[ "$AUTH_MODE" == "proxy" ]]; then
    echo "==> Deploying ${MIRROR_TOOL} mirror (kind + cgr-oidc-proxy + tool)..."
  else
    echo "==> Deploying ${MIRROR_TOOL} mirror (kind + chainctl pull token + tool)..."
  fi
  CHAINGUARD_ORG="$ORG" AUTH_MODE="$AUTH_MODE" PULL_TOKEN_TTL="$PULL_TOKEN_TTL" \
    "mirrors/${MIRROR_TOOL}/deploy.sh"

  # Mirror modes don't use the Jenkins OIDC assumed identity at runtime;
  # truncate IDENTITY so cgLogin won't try the chainctl path.
  IDENTITY_FILE=shared-libraries/cg-images/IDENTITY
  : > "$IDENTITY_FILE"
fi

echo
echo "==> Done."
echo "    Open $JENKINS_URL (admin/admin) and trigger any pipeline."
echo
echo "    Mirror tool:    ${MIRROR_TOOL}"
echo "    Pulls from:     ${PULL_REGISTRY}"
echo "    Pushes to:      ${PUSH_REGISTRY}"
case "$MIRROR_TOOL" in
  harbor)       echo "    Harbor UI:      https://localhost/harbor (admin / Harbor12345; click through cert warning)" ;;
  distribution) echo "    distribution:   pull http://localhost:5050   push http://localhost:5051" ;;
  zot)          echo "    zot:            http://localhost:5052/v2/_catalog" ;;
  nexus-ce)     echo "    Nexus CE UI:    http://localhost:8081 (admin / admin123)" ;;
  jcr)          echo "    JCR UI:         http://localhost:8082 (admin / password)" ;;
esac
