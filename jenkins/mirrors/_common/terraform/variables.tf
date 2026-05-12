variable "chainguard_organization_name" {
  type        = string
  description = "Chainguard org being proxied (matches CHAINGUARD_ORG used elsewhere in the demo)."
}

variable "k8s_cluster_issuer" {
  type        = string
  description = "OIDC issuer URL for the kind cluster's service-account tokens. The static block does offline JWKS verification (see k8s-jwks.json captured at deploy time), so this URL never has to resolve from Chainguard's side."
  default     = "https://kubernetes.default.svc.cluster.local"
}

variable "identity_expiration" {
  type        = string
  description = "RFC3339 timestamp at which the assumed identity stops accepting tokens. Must be in the future. Defaults to one year from a fixed-but-recent baseline; bump or rotate by running bootstrap.sh again."
  default     = "2027-05-07T00:00:00Z"
}
