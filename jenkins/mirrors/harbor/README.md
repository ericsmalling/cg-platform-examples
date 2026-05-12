# jenkins/mirrors/harbor — Optional Harbor pull-through cache

Stands up a [Harbor](https://goharbor.io/) registry in a local `kind` cluster, configured as a **pull-through cache** for `cgr.dev/${CHAINGUARD_ORG}/*`. Optionally also serves as a **push target** for the demo's OCI-image pipelines (Python and Node samples), replacing `ttl.sh`.

This directory is a lightly-adapted copy of [chainguard-demo/cs-workshop/.../harbor](https://github.com/chainguard-demo/cs-workshop/tree/main/trainer-development/operations-track/harbor) — the `deploy.sh` script is rewired to be env-var-driven (callable from `setup.sh`) and the Terraform module drops the replication-mirror project we don't need.

## When you'd want this

The default demo pulls Chainguard images directly from `cgr.dev/$CHAINGUARD_ORG` (using the OIDC assumed-identity flow). With Harbor in front:

- **Faster repeated pulls** — Harbor caches manifests and layers locally, so the second pull of `maven:3-jdk17-dev` is bytes-from-localhost.
- **No long-lived credentials anywhere** — neither in Jenkins nor in Harbor. An in-cluster `cgr-oidc-proxy` Deployment fronts cgr.dev: it holds a projected k8s ServiceAccount JWT, exchanges it at Chainguard's STS for a short-lived registry bearer, and injects that on every outbound request. kubelet reaches the proxy via a containerd registry mirror; Harbor reaches it via a Service. The 30-day pull token (and the `regcred` Secret it powered) is gone.
- **A demo-able push target** — instead of pushing built images to `ttl.sh` (24h TTL, world-readable), pipelines can push to Harbor's `library` project where they persist.

## Architecture

```
                       ┌─ host ─────────────────────────────────────┐
                       │                                            │
                       │  kind cluster (jenkins-mirrors)            │
   docker pull         │   ┌───────────────────────────────────┐    │
   localhost/cgr-proxy │   │  ingress-nginx :80/:443           │    │
   ──────────────────▶ │   │   │                               │    │
                       │   │   ▼                               │    │
                       │   │  harbor-{portal,core,registry}    │    │      cgr.dev
                       │   │   │                               │    │  ◀──────────
                       │   │   ▼  (proxy-cache pulls)          │    │
                       │   │  cgr-oidc-proxy ──────────────────┼────┼──▶
                       │   │   ▲ (projected SA JWT             │    │
                       │   │   │  exchanged at Chainguard STS  │    │
                       │   │   │  for short-lived bearer)      │    │
                       │   │   │                               │    │
                       │   │  kubelet (containerd mirror) ─────┘    │
                       │   └───────────────────────────────────┘    │
                       │                                            │
                       └────────────────────────────────────────────┘
```

Harbor microservices run in the `mirror-harbor` namespace; the cgr-oidc-proxy in its own `cgr-oidc-proxy` namespace (shared with any other mirror tool the demo can stand up); ingress-nginx in `ingress-nginx`. Both Harbor and ingress-nginx pull `cgr.dev/$CHAINGUARD_ORG/*` images via the kind node's containerd, which is configured (`../_common/kind/config.yaml`) to mirror `cgr.dev` to the proxy on `127.0.0.1:5000`. The proxy authenticates to cgr.dev using a Chainguard `chainguard_identity` whose trust policy is the kind cluster's OIDC issuer — the cluster's JWKS is captured at deploy time and uploaded statically. No cgr.dev credentials of any kind live on disk or in a Kubernetes Secret.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | One-shot: sources the shared bootstrap (kind + JWKS + chainguard_identity + cgr-oidc-proxy), then deploys ingress-nginx + Harbor and runs Harbor's stage-2 terraform to register the proxy as the upstream registry. Idempotent. Driven by env vars. |
| [`teardown.sh`](teardown.sh) | `kind delete cluster --name jenkins-mirrors`. |
| [`../_common/kind/config.yaml`](../_common/kind/config.yaml) | Shared kind cluster definition: host port 80/443 mappings + a `containerdConfigPatches` block mirroring `cgr.dev` to the proxy. Used by every mirror tool. |
| [`../_common/bootstrap.sh`](../_common/bootstrap.sh) | Shared bootstrap library: kind cluster + namespaces + JWKS capture + stage-1 terraform + cgr-oidc-proxy build/deploy. Sourced by every mirror's `deploy.sh`. |
| [`../_common/terraform/`](../_common/terraform/) | Stage-1 terraform: `chainguard_identity` the proxy assumes (with role binding for `registry.pull`). Shared across all mirror tools. |
| [`../../cgr-oidc-proxy/`](../../cgr-oidc-proxy/) | The OIDC-fronted reverse proxy: small Go binary, Dockerfile, k8s Deployment/Service/ServiceAccount. Shared. |
| [`cg/helm/values.template`](cg/helm/values.template) | Harbor Helm values, parameterized on `${REGISTRY_URL}` so all images come from the configured Chainguard org. |
| [`cg/manifests/deploy-ingress-nginx.template`](cg/manifests/deploy-ingress-nginx.template) | ingress-nginx static manifest, parameterized on `${REGISTRY_URL}`. |
| [`terraform/main.tf`](terraform/main.tf) | Stage-2 terraform: Harbor's upstream registry pointing at the in-cluster proxy + the `cgr-proxy` proxy-cache project. |

## Direct invocation (for debugging)

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into Harbor mode. To run it by hand:

```sh
export CHAINGUARD_ORG=your-org-here  # whichever org owns the catalog
./deploy.sh
```

You'll need `chainctl` already authenticated against the Chainguard org so the terraform `chainguard` provider can create the identity.

The Harbor admin UI is at <https://localhost/harbor> (`admin` / `Harbor12345`). The chart issues a self-signed cert, so browsers will show a one-time warning — click through. Tear down with `./teardown.sh`.

> **Why HTTPS for the UI but HTTP for the registry?** Harbor 2.12.3+ ships with `gorilla/csrf` v1.7.3, which hardcodes the request scheme to `https` inside its origin check. Harbor's middleware doesn't compensate, so a plain-HTTP `POST /c/login` is rejected with `403 origin invalid` before the password is even checked (upstream bug: [goharbor/harbor#22010](https://github.com/goharbor/harbor/issues/22010)). The Docker daemon, in turn, refuses HTTPS connections to `127.0.0.0/8` by default, so the registry path (`/v2/`, `/service/token`, etc.) must remain reachable over HTTP. We split the two: TLS is enabled on the ingress for the UI, but `ssl-redirect` is off so HTTP isn't forced — the `externalURL` stays `http://localhost` so Harbor advertises HTTP to docker clients. Browser users type `https://`, pipelines push over `http://`, both work.
