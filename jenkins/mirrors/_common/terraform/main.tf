terraform {
  required_providers {
    chainguard = {
      source  = "chainguard-dev/chainguard"
      version = "~> 0.2"
    }
  }
}

provider "chainguard" {}

# Resolve the parent group — the Chainguard org whose catalog the in-cluster
# cgr-oidc-proxy fronts. The name comes in via -var (driven by the caller's
# CHAINGUARD_ORG, rendered into terraform.tfvars by bootstrap.sh).
data "chainguard_group" "parent" {
  name = var.chainguard_organization_name
}

# Look up the registry.pull role.
data "chainguard_role" "puller" {
  name = "registry.pull"
}

# Identity that the in-cluster cgr-oidc-proxy assumes via its projected
# k8s ServiceAccount JWT. The kind cluster's service-account-issuer
# (`https://kubernetes.default.svc.cluster.local`) is not publicly
# reachable, so we upload the JWKS statically — captured at deploy time
# via `kubectl get --raw /openid/v1/jwks` (see bootstrap.sh).
# Mirrors the pattern used for the Jenkins identity in iac/main.tf.
#
# Shared by all OCI mirror tools (harbor, distribution, zot, nexus-ce, jcr):
# the proxy itself is a single Deployment in the `cgr-oidc-proxy` namespace,
# and each mirror tool simply points at it.
resource "chainguard_identity" "cgr_proxy" {
  parent_id   = data.chainguard_group.parent.id
  name        = "cgr-oidc-proxy"
  description = "OIDC-fronted registry proxy shared by all OCI mirror demos; assumes via k8s SA token"

  static {
    issuer      = var.k8s_cluster_issuer
    subject     = "system:serviceaccount:cgr-oidc-proxy:cgr-oidc-proxy"
    issuer_keys = file("${path.module}/k8s-jwks.json")
    expiration  = var.identity_expiration
  }
}

# Grant the proxy identity registry.pull on the parent group so it can
# pull any cgr.dev/<group>/<image>:<tag> covered by the cgImages catalog.
resource "chainguard_rolebinding" "cgr_proxy_pulls" {
  identity = chainguard_identity.cgr_proxy.id
  group    = data.chainguard_group.parent.id
  role     = data.chainguard_role.puller.items[0].id
}

# Exported so bootstrap.sh can inject this UIDP into the proxy's ConfigMap;
# the proxy presents it as the `identity` parameter when exchanging its
# SA JWT at Chainguard's STS.
output "proxy_identity_uidp" {
  description = "UIDP of the cgr-oidc-proxy Chainguard identity. bootstrap.sh injects this into the proxy's ConfigMap."
  value       = chainguard_identity.cgr_proxy.id
}
