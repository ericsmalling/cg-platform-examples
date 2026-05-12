#!/usr/bin/env bash
# Shared bootstrap library for the OCI mirror demos. Each mirror's deploy.sh
# sources this file and calls the functions below in order to:
#   1. Create (or reuse) a single kind cluster shared across mirrors.
#   2. Create the per-mirror + cgr-oidc-proxy + ingress-nginx namespaces.
#   3. Capture the cluster's OIDC JWKS so Chainguard's STS can verify the
#      proxy's projected ServiceAccount tokens offline.
#   4. Run terraform stage 1 (chainguard_identity + rolebinding) from
#      mirrors/_common/terraform/. The output PROXY_UIDP feeds the proxy's
#      ConfigMap.
#   5. Build & side-load the cgr-oidc-proxy container image into kind.
#   6. Apply the proxy Deployment/Service/ServiceAccount manifests and wait
#      for it to become Ready.
#
# After bootstrap returns, each mirror tool is responsible for its own
# tool-specific deployment (Helm chart, manifest, terraform stage 2, etc.).
#
# Required env vars:
#   CHAINGUARD_ORG       Chainguard org being proxied
# Optional env vars:
#   KIND_CLUSTER_NAME    default: jenkins-mirrors
#   COMMON_DIR           absolute path to mirrors/_common (auto-derived from
#                         this file's location if not set)
#   MIRROR_NAMESPACE     additional namespace to create (caller's mirror
#                         tool's ns, e.g. mirror-harbor). Optional; if empty,
#                         only cgr-oidc-proxy + ingress-nginx are created.
#   PROXY_NAMESPACE      override for the proxy's namespace. Default:
#                         cgr-oidc-proxy. Must match the namespace baked
#                         into cgr-oidc-proxy/k8s/deployment.yaml.
#
# Idempotent: every step re-applies the manifests, helm values, and
# terraform with up-to-date inputs.

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
  for tool in kind kubectl terraform envsubst docker python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: $tool not found in PATH" >&2
      return 1
    fi
  done
}

common::ensure_kind_cluster() {
  if ! kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
    echo "==> Creating kind cluster '$KIND_CLUSTER_NAME'..."
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$COMMON_DIR/kind/config.yaml"
    kubectl wait --for=condition=Ready "node/${KIND_CLUSTER_NAME}-control-plane" --timeout=2m
  else
    echo "==> kind cluster '$KIND_CLUSTER_NAME' already exists, reusing it."
    # `kind export kubeconfig` is idempotent and recreates the context if it
    # was wiped (e.g. by a prior failed run or `kubectl config delete-context`).
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

# Convenience: run the full bootstrap end-to-end. Mirror deploy.sh scripts
# can either call this single helper, or call the individual steps if they
# need to interleave their own logic.
common::bootstrap_all() {
  : "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set}"
  common::require_tools
  common::ensure_kind_cluster
  common::ensure_namespaces
  common::capture_jwks
  local uidp
  uidp="$(common::terraform_identity)"
  common::ensure_proxy_configmap "$uidp"
  common::build_and_load_proxy
  common::deploy_proxy
}
