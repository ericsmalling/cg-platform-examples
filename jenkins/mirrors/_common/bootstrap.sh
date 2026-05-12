#!/usr/bin/env bash
# Shared bootstrap library for the OCI mirror demos. Each mirror's deploy.sh
# sources this file and calls the functions below in order to:
#   1. Create (or reuse) a single kind cluster shared across mirrors.
#   2. Create the per-mirror + cgr-oidc-proxy + ingress-nginx namespaces.
#   3. Depending on $AUTH_MODE (set by setup.sh):
#        proxy mode      — capture JWKS, run terraform stage 1, build+load+
#                          deploy cgr-oidc-proxy. No long-lived creds.
#        pull-token mode — mint a chainctl pull token (TTL from
#                          $PULL_TOKEN_TTL), cache it under
#                          mirrors/_common/.pull-tokens/<tool>.json
#                          (gitignored), and create a `regcred` Secret in
#                          $MIRROR_NAMESPACE that the mirror tool's
#                          per-tool config references.
#
# After bootstrap returns, each mirror tool is responsible for its own
# tool-specific deployment (Helm chart, manifest, terraform stage 2, etc.).
#
# Required env vars:
#   CHAINGUARD_ORG       Chainguard org being proxied
#   MIRROR_NAMESPACE     caller's mirror tool's ns (e.g. mirror-harbor).
#                         Always required: in pull-token mode it hosts
#                         the regcred Secret; in proxy mode it's the ns
#                         the mirror tool itself lives in.
# Optional env vars:
#   AUTH_MODE            'proxy' (default) or 'pull-token'. Set by setup.sh.
#   PULL_TOKEN_TTL       chainctl-format duration (e.g. 168h). Required when
#                         AUTH_MODE=pull-token.
#   KIND_CLUSTER_NAME    default: jenkins-mirrors
#   COMMON_DIR           absolute path to mirrors/_common (auto-derived from
#                         this file's location if not set)
#   PROXY_NAMESPACE      override for the proxy's namespace. Default:
#                         cgr-oidc-proxy. Must match the namespace baked
#                         into cgr-oidc-proxy/k8s/deployment.yaml.
#
# Idempotent: every step re-applies the manifests, helm values, and
# terraform with up-to-date inputs. In pull-token mode an existing cache
# file is reused as-is (re-run after `./teardown.sh` to rotate).

# Derive COMMON_DIR from BASH_SOURCE if the caller didn't set it. Use
# python3 to do an absolute realpath, since macOS readlink doesn't accept -f.
if [[ -z "${COMMON_DIR:-}" ]]; then
  COMMON_DIR="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.realpath(sys.argv[1])))' "${BASH_SOURCE[0]}")"
fi
# Path to cgr-oidc-proxy/ — lives at the *parent* repo root
# (cg-platform-examples/cgr-oidc-proxy), one level above the Jenkins demo.
# COMMON_DIR is .../cg-platform-examples/jenkins/mirrors/_common, so up
# three levels (_common → mirrors → jenkins) lands on the repo root.
# Overridable via PROXY_DIR if the proxy is checked out somewhere else.
PROXY_DIR="${PROXY_DIR:-$(python3 -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], "..", "..", "..", "cgr-oidc-proxy")))' "$COMMON_DIR")}"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jenkins-mirrors}"
PROXY_NAMESPACE="${PROXY_NAMESPACE:-cgr-oidc-proxy}"

common::require_tools() {
  local tool
  # Base tools needed by every mode.
  for tool in kind kubectl envsubst docker python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: $tool not found in PATH" >&2
      return 1
    fi
  done
  # Mode-specific tools.
  case "${AUTH_MODE:-proxy}" in
    proxy)
      if ! command -v terraform >/dev/null 2>&1; then
        echo "ERROR: terraform not found in PATH (required for proxy auth mode)" >&2
        return 1
      fi
      ;;
    pull-token)
      if ! command -v chainctl >/dev/null 2>&1; then
        echo "ERROR: chainctl not found in PATH (required for pull-token auth mode)" >&2
        return 1
      fi
      ;;
  esac
}

common::ensure_kind_cluster() {
  if ! kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
    echo "==> Rendering kind config for AUTH_MODE=${AUTH_MODE:-proxy}..."
    # The containerd registry-mirror block only applies in proxy mode (where
    # cgr-oidc-proxy is reachable on 127.0.0.1:5000 via hostNetwork). In
    # pull-token mode the cluster runs without the mirror and kubelet pulls
    # cgr.dev images directly using regcred imagePullSecrets.
    if [[ "${AUTH_MODE:-proxy}" == "pull-token" ]]; then
      CONTAINERD_PATCHES_BLOCK="# (AUTH_MODE=pull-token: no containerd mirror)"
    else
      CONTAINERD_PATCHES_BLOCK=$'containerdConfigPatches:\n  - |-\n    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."cgr.dev"]\n      endpoint = ["http://127.0.0.1:5000"]'
    fi
    export CONTAINERD_PATCHES_BLOCK
    envsubst '${CONTAINERD_PATCHES_BLOCK}' \
      < "$COMMON_DIR/kind/config.yaml.template" \
      > "$COMMON_DIR/kind/config.yaml"
    echo "==> Creating kind cluster '$KIND_CLUSTER_NAME'..."
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$COMMON_DIR/kind/config.yaml"
    kubectl wait --for=condition=Ready "node/${KIND_CLUSTER_NAME}-control-plane" --timeout=2m
  else
    echo "==> kind cluster '$KIND_CLUSTER_NAME' already exists, reusing it."
    # `kind export kubeconfig` is idempotent and recreates the context if it
    # was wiped (e.g. by a prior failed run or `kubectl config delete-context`).
    # NOTE: an existing cluster keeps the containerd config it was created
    # with. Switching AUTH_MODE on a live cluster requires teardown + setup.
    kind export kubeconfig --name "$KIND_CLUSTER_NAME"
  fi
}

common::ensure_namespaces() {
  echo "==> Ensuring namespaces..."
  local ns
  for ns in "$PROXY_NAMESPACE" ingress-nginx ${MIRROR_NAMESPACE:-}; do
    [[ -z "$ns" ]] && continue
    kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
  done
}

common::capture_jwks() {
  echo "==> Capturing cluster JWKS for the OIDC proxy identity..."
  kubectl get --raw /openid/v1/jwks > "$COMMON_DIR/terraform/k8s-jwks.json"
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$COMMON_DIR/terraform/k8s-jwks.json" >/dev/null 2>&1; then
    echo "ERROR: $COMMON_DIR/terraform/k8s-jwks.json is not valid JSON. Got:" >&2
    cat "$COMMON_DIR/terraform/k8s-jwks.json" >&2
    return 1
  fi
}

# Runs terraform stage 1 from mirrors/_common/terraform/ — chainguard_identity
# + rolebinding only. Echoes the resulting UIDP on stdout so the caller can
# capture it. (The caller should also be able to re-read it via `terraform
# output -raw proxy_identity_uidp` from $COMMON_DIR/terraform.)
common::terraform_identity() {
  echo "==> Rendering terraform.tfvars for stage 1..." >&2
  ORG_NAME="${CHAINGUARD_ORG}" envsubst < "$COMMON_DIR/terraform/terraform.templatevars" \
    > "$COMMON_DIR/terraform/terraform.tfvars"

  echo "==> Creating chainguard_identity for the proxy (terraform stage 1)..." >&2
  ( cd "$COMMON_DIR/terraform"
    terraform init -input=false -upgrade
    terraform apply -input=false -auto-approve
  ) >&2

  local uidp
  uidp="$(cd "$COMMON_DIR/terraform" && terraform output -raw proxy_identity_uidp)"
  if [[ -z "$uidp" ]]; then
    echo "ERROR: terraform output proxy_identity_uidp was empty." >&2
    return 1
  fi
  printf '%s\n' "$uidp"
}

# $1 = PROXY_UIDP returned by common::terraform_identity
common::ensure_proxy_configmap() {
  local uidp="${1:?common::ensure_proxy_configmap requires PROXY_UIDP arg}"
  echo "==> Writing cgr-oidc-proxy-config ConfigMap..."
  kubectl -n "$PROXY_NAMESPACE" create configmap cgr-oidc-proxy-config \
    --from-literal=identity="$uidp" \
    --dry-run=client -o yaml | kubectl apply -f -
}

common::build_and_load_proxy() {
  echo "==> Building cgr-oidc-proxy image..."
  docker build --build-arg CHAINGUARD_ORG="${CHAINGUARD_ORG}" \
    -t cgr-oidc-proxy:dev "$PROXY_DIR"

  echo "==> Loading cgr-oidc-proxy image into kind..."
  kind load docker-image cgr-oidc-proxy:dev --name "$KIND_CLUSTER_NAME"
}

common::deploy_proxy() {
  echo "==> Deploying cgr-oidc-proxy..."
  # Apply every YAML under k8s/. The Deployment + Service are always there;
  # networkpolicy.yaml ships alongside but only takes effect if the CNI
  # honors NetworkPolicy (kindnet does on recent kind versions).
  kubectl apply -f "$PROXY_DIR/k8s/"
  # Re-running setup picks up a possibly-changed ConfigMap; force a roll so
  # the proxy reads the current UIDP.
  kubectl -n "$PROXY_NAMESPACE" rollout restart deployment/cgr-oidc-proxy
  kubectl -n "$PROXY_NAMESPACE" rollout status deployment/cgr-oidc-proxy --timeout=2m
}

# Mint (or reuse) a chainctl pull token, cache it locally, and create a
# `regcred` dockerconfigjson Secret in $MIRROR_NAMESPACE so the mirror
# tool's pod can pull from cgr.dev directly. Also exports PULL_USER /
# PULL_PASS for the caller to embed in tool-specific config (zot
# credentialsFile, Nexus connector creds, etc.).
#
# $1 = tool name (e.g. 'harbor'). Used as the chainctl --name and the cache
# filename so teardown can find the right token to delete.
common::bootstrap_pull_token() {
  local tool="${1:?common::bootstrap_pull_token requires <tool> arg}"
  : "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"
  : "${PULL_TOKEN_TTL:?PULL_TOKEN_TTL must be set in pull-token mode}"
  : "${MIRROR_NAMESPACE:?MIRROR_NAMESPACE must be set}"

  local cache_dir="$COMMON_DIR/.pull-tokens"
  mkdir -p "$cache_dir"
  chmod 700 "$cache_dir" 2>/dev/null || true
  local cache_file="$cache_dir/${tool}.json"
  local token_name="jenkins-mirror-${tool}"

  if [[ -f "$cache_file" ]] && \
     python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("name")==sys.argv[2] else 1)' \
       "$cache_file" "$token_name" 2>/dev/null; then
    echo "==> Reusing cached pull token from $cache_file" >&2
  else
    echo "==> Minting Chainguard pull token (name=$token_name, ttl=$PULL_TOKEN_TTL)..." >&2
    # chainctl returns at least { identity_id, token } and usually an `id`
    # too. We persist the full object so teardown can pick whichever
    # identifier the installed chainctl version expects for deletion
    # without us hardcoding a field name here.
    local raw
    raw=$(chainctl auth pull-token create \
            --parent="$CHAINGUARD_ORG" \
            --name="$token_name" \
            --ttl="$PULL_TOKEN_TTL" \
            -o json)
    if ! printf '%s' "$raw" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
      echo "ERROR: chainctl returned non-JSON output:" >&2
      echo "$raw" >&2
      return 1
    fi
    # Stamp `name` back in (chainctl may or may not echo it) so teardown
    # can match the cache file to a token-name pattern.
    printf '%s' "$raw" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["name"] = sys.argv[1]
json.dump(d, sys.stdout)
' "$token_name" > "$cache_file"
    chmod 600 "$cache_file"
    echo "    Token cached at $cache_file (gitignored)." >&2
  fi

  PULL_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("identity_id",""))' "$cache_file")"
  PULL_PASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token",""))' "$cache_file")"
  if [[ -z "$PULL_USER" || -z "$PULL_PASS" ]]; then
    echo "ERROR: cached pull-token JSON at $cache_file missing identity_id or token." >&2
    return 1
  fi
  export PULL_USER PULL_PASS

  # regcred Secret in the mirror namespace. Harbor's RegistryEndpoint and
  # any pod-level imagePullSecret consume this directly; the other 4 tools
  # don't read k8s Secrets — they read $PULL_USER/$PULL_PASS via envsubst
  # or per-tool REST bootstrap. We create the Secret in both cases since
  # it's cheap and helps debugging (kubectl get secret -n mirror-* regcred).
  echo "==> Creating regcred Secret in namespace $MIRROR_NAMESPACE..." >&2
  kubectl -n "$MIRROR_NAMESPACE" create secret docker-registry regcred \
    --docker-server="cgr.dev" \
    --docker-username="$PULL_USER" \
    --docker-password="$PULL_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# Convenience: run the full bootstrap end-to-end. Branches on AUTH_MODE.
# Mirror deploy.sh scripts can call this single helper, or call the
# individual steps if they need to interleave tool-specific logic.
common::bootstrap_all() {
  : "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"
  : "${MIRROR_NAMESPACE:?MIRROR_NAMESPACE must be set by the caller}"
  local mode="${AUTH_MODE:-proxy}"
  common::require_tools
  common::ensure_kind_cluster
  common::ensure_namespaces
  case "$mode" in
    proxy)
      common::capture_jwks
      local uidp
      uidp="$(common::terraform_identity)"
      common::ensure_proxy_configmap "$uidp"
      common::build_and_load_proxy
      common::deploy_proxy
      ;;
    pull-token)
      # Derive the tool name from $MIRROR_NAMESPACE ("mirror-harbor" → "harbor").
      common::bootstrap_pull_token "${MIRROR_NAMESPACE#mirror-}"
      ;;
    *)
      echo "ERROR: unknown AUTH_MODE='$mode' (expected: proxy | pull-token)" >&2
      return 1
      ;;
  esac
}
