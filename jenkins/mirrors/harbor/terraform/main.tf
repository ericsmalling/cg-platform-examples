terraform {
  required_providers {
    harbor = {
      source  = "goharbor/harbor"
      version = "~> 3.10"
    }
  }
}

# The Harbor admin password matches the Helm chart default. If you override
# the chart value `harborAdminPassword`, change this too.
# `insecure = true` skips TLS verification — the chart issues a self-signed
# cert (see mirrors/harbor/cg/helm/values.template for why we can't run HTTP).
provider "harbor" {
  url      = "https://localhost"
  username = "admin"
  password = "Harbor12345"
  insecure = true
}

# Upstream registry that Harbor's proxy-cache project pulls from. Defaults
# point at the in-cluster cgr-oidc-proxy (AUTH_MODE=proxy): Harbor talks to
# it with empty credentials and the proxy injects a short-lived Chainguard
# bearer derived from a projected k8s SA JWT. In AUTH_MODE=pull-token,
# deploy.sh overrides these vars via `-var=` to point Harbor straight at
# https://cgr.dev with a long-lived chainctl pull token as basic auth.
variable "endpoint_url" {
  type    = string
  default = "http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000"
}

variable "access_id" {
  type    = string
  default = ""
}

variable "access_secret" {
  type      = string
  default   = ""
  sensitive = true
}

# Register the upstream as Harbor's "registry". The goharbor provider
# requires `access_id`/`access_secret` to be present strings; in proxy mode
# they're empty and the proxy strips any inbound Authorization header
# before forwarding to cgr.dev.
#
# The proxy (when used) lives in its own `cgr-oidc-proxy` namespace (shared
# by all mirrors) — the chainguard_identity + rolebinding behind it are
# managed in mirrors/_common/terraform/ (stage 1, applied by the bootstrap
# before this stage runs).
resource "harbor_registry" "cgr_dev" {
  provider_name = "docker-registry"
  name          = "cgr.dev"
  endpoint_url  = var.endpoint_url
  access_id     = var.access_id
  access_secret = var.access_secret
}

# Public proxy-cache project. Anonymous pulls of
# `localhost/cgr-proxy/<org>/<image>:<tag>` lazily fetch from cgr.dev on
# first hit and cache locally; subsequent pulls hit Harbor's local copy.
# (Harbor's default `library` project is reused for pushes — no extra
# resource needed.)
resource "harbor_project" "cgr_proxy" {
  name        = "cgr-proxy"
  public      = true
  registry_id = harbor_registry.cgr_dev.registry_id
}
