# cgr-oidc-proxy

A small reverse proxy for [`cgr.dev`](https://cgr.dev) (Chainguard's container registry) that authenticates outbound requests using a short-lived bearer minted from a Kubernetes ServiceAccount JWT — so consumers (OCI registries, image-pull clients, anything that wants to fetch from cgr.dev) don't need to hold a long-lived Chainguard pull token.

```
              consumer (e.g. Harbor, distribution, zot, Nexus, JCR, kubelet)
              │
              │ HTTP, no credentials
              ▼
        ┌─────────────────────┐    projected k8s SA token
        │   cgr-oidc-proxy    │ ───▶ Chainguard STS (issuer.enforce.dev)
        │                     │ ◀─── short-lived registry bearer
        └─────────────────────┘
              │
              │ Authorization: Bearer <token>
              ▼
            cgr.dev
```

The proxy reads a projected ServiceAccount token from a mounted file, exchanges it at Chainguard's STS for a Chainguard registry bearer, caches that bearer in-memory, and refreshes ~60s before its expiry (with exponential backoff on STS failure). Outbound requests to `cgr.dev` get the bearer attached by [`go-containerregistry`'s `transport.New`](https://pkg.go.dev/github.com/google/go-containerregistry/pkg/v1/remote/transport#New), which also handles the standard OCI `WWW-Authenticate: Bearer realm=…` challenge dance.

The proxy is intentionally `cgr.dev`-specific: upstream host, STS issuer, and audience are constants, not configurable. If you need an analogous proxy for a different registry, fork it.

## Files

| Path | Purpose |
|---|---|
| `main.go` | The proxy itself (~315 lines). Stdlib `net/http` + `httputil.ReverseProxy`, with a custom `RoundTripper` that lazily builds `transport.New` on first request (so the binary starts even if the SA token isn't readable yet, and retries on next request). |
| `Dockerfile` | Multi-stage build. Builder: `cgr.dev/${CHAINGUARD_ORG}/go:latest-dev`. Final: `cgr.dev/${CHAINGUARD_ORG}/static:latest`. Runs as nonroot uid 65532. `ARG CHAINGUARD_ORG=chainguard` defaults to the public catalog so anyone can build. |
| `k8s/deployment.yaml` | ServiceAccount + Deployment + Service. Pod runs with `hostNetwork: true` so containerd registry mirrors can reach it on `127.0.0.1:5000` — drop that if your consumer reaches the proxy via the cluster Service only. |

## Prerequisites

1. **A Kubernetes cluster** with the [`ServiceAccountTokenAudiences`](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#token-controller) feature (≥ 1.20). Projected SA tokens are how the proxy proves its identity to Chainguard's STS.
2. **A Chainguard org and identity.** Create a `chainguard_identity` whose trust policy accepts JWTs from your cluster's OIDC issuer. Bind it to the `registry.pull` role on the group you want to pull from. Capture the identity's UIDP — you'll inject it into the proxy at runtime.
3. **(Recommended) Cluster JWKS uploaded statically.** Most clusters' `--service-account-issuer` (`https://kubernetes.default.svc.cluster.local`) is not reachable from outside, so Chainguard's STS can't fetch the JWKS to validate JWTs. Capture it once with `kubectl get --raw /openid/v1/jwks` and pass it as `static.issuer_keys` on the `chainguard_identity`.

### Option A: Terraform

Matches what the Jenkins demo does — see [`jenkins/mirrors/_common/terraform/main.tf`](../jenkins/mirrors/_common/terraform/main.tf) for the full thing:

```hcl
data "chainguard_group" "parent" { name = var.chainguard_organization_name }
data "chainguard_role" "puller"  { name = "registry.pull" }

resource "chainguard_identity" "cgr_proxy" {
  parent_id = data.chainguard_group.parent.id
  name      = "cgr-oidc-proxy"

  static {
    issuer      = "https://kubernetes.default.svc.cluster.local"
    subject     = "system:serviceaccount:cgr-oidc-proxy:cgr-oidc-proxy"
    issuer_keys = file("${path.module}/k8s-jwks.json")
    expiration  = "2027-05-07T00:00:00Z"
  }
}

resource "chainguard_rolebinding" "cgr_proxy_pulls" {
  identity = chainguard_identity.cgr_proxy.id
  group    = data.chainguard_group.parent.id
  role     = data.chainguard_role.puller.items[0].id
}

output "proxy_identity_uidp" {
  value = chainguard_identity.cgr_proxy.id
}
```

### Option B: chainctl + kubectl (no Terraform)

You can do the whole setup imperatively with [`chainctl`](https://edu.chainguard.dev/chainguard/chainctl/) and `kubectl`. Run these from a shell with `chainctl auth login` already done.

```sh
# 0. Set the org you're pulling images from. Pick whichever group your
#    catalog images live under — e.g. 'chainguard' for the public catalog,
#    or 'your-org.example.com' for your own private one.
ORG="chainguard"

# 1. Capture the cluster's OIDC JWKS. Chainguard's STS uses this to verify
#    the projected SA tokens the proxy will present. The default cluster
#    issuer URL (https://kubernetes.default.svc.cluster.local) isn't
#    publicly reachable, so we upload the keys statically instead of
#    asking Chainguard to fetch them.
kubectl get --raw /openid/v1/jwks > /tmp/k8s-jwks.json

# 2. Create the chainguard_identity with the SA-token trust policy.
#    --role=registry.pull also creates the rolebinding in the same call.
#    Capture the printed UIDP — you'll need it for the proxy ConfigMap.
chainctl iam identities create cgr-oidc-proxy \
  --parent="${ORG}" \
  --identity-issuer="https://kubernetes.default.svc.cluster.local" \
  --subject="system:serviceaccount:cgr-oidc-proxy:cgr-oidc-proxy" \
  --issuer-keys="$(cat /tmp/k8s-jwks.json)" \
  --expiration="$(date -u -v+1y '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 year' '+%Y-%m-%dT%H:%M:%SZ')" \
  --role=registry.pull

# 3. Grab the UIDP for the identity you just created. (You could also
#    capture it from step 2's output and skip this lookup.)
UIDP="$(chainctl iam identities list --parent="${ORG}" -o json \
  | python3 -c 'import json,sys; print(next(i["id"] for i in json.load(sys.stdin) if i["name"]=="cgr-oidc-proxy"))')"
echo "Proxy UIDP: $UIDP"
```

`--expiration` is when Chainguard stops accepting tokens signed by these JWKS keys — *not* the per-token expiry. Bump it before it lapses, or rotate the JWKS by re-running the identity create. The default and ceiling is 30 days; the example bumps to a year for demos.

You now have a UIDP. Hand it to the proxy via the `CGR_IDENTITY` env var (which the Deployment manifest reads from a ConfigMap — see Deploy section).

To verify:

```sh
chainctl iam identities list --parent="${ORG}" \
  | grep cgr-oidc-proxy

chainctl iam role-bindings list --parent="${ORG}" \
  | grep "cgr-oidc-proxy"
```

To clean up:

```sh
chainctl iam identities delete "$UIDP"
# Role bindings are deleted automatically with the identity.
```

## Deploy

```sh
# 1. Build the image (defaults to the public Chainguard catalog).
docker build -t cgr-oidc-proxy:dev .

# 2. Load it into your cluster (for kind / minikube / k3d).
kind load docker-image cgr-oidc-proxy:dev --name <cluster-name>

# 3. Apply manifests — creates the cgr-oidc-proxy namespace, ServiceAccount,
#    Deployment, Service. The Deployment depends on a ConfigMap that's
#    created in step 4.
kubectl create namespace cgr-oidc-proxy
kubectl apply -f k8s/deployment.yaml

# 4. Write the chainguard_identity UIDP into the ConfigMap.
kubectl -n cgr-oidc-proxy create configmap cgr-oidc-proxy-config \
  --from-literal=identity="$(terraform output -raw proxy_identity_uidp)"

# 5. Rollout-restart so the proxy picks up the ConfigMap.
kubectl -n cgr-oidc-proxy rollout restart deployment/cgr-oidc-proxy
kubectl -n cgr-oidc-proxy rollout status  deployment/cgr-oidc-proxy --timeout=2m
```

The proxy is now reachable in-cluster at `http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000`, and on the node's loopback at `http://127.0.0.1:5000` (because of `hostNetwork: true`).

## Configuration

| Flag | Env | Default | Purpose |
|---|---|---|---|
| `--listen` | — | `:5000` | Address the proxy listens on. |
| `--token-file` | — | `/var/run/secrets/cgr/token` | Path to the projected SA JWT. kubelet rotates the file in place; the proxy reads it on each refresh. |
| `--identity` | `CGR_IDENTITY` | (required) | The Chainguard identity UIDP to assume during STS token exchange. |

The Deployment manifest mounts a projected token with audience `issuer.enforce.dev` at the default path, and pulls `CGR_IDENTITY` from the `cgr-oidc-proxy-config` ConfigMap's `identity` key.

## Wiring it to a consumer

Point your consumer at the proxy as if it were `cgr.dev`, with **no credentials**. The proxy supplies its own.

- **Harbor** "Registry endpoint" → URL `http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000`, empty access_id/secret. Then create a proxy-cache project against it.
- **distribution/distribution** `proxy.remoteurl` in `config.yml` → same URL, no `proxy.username`/`proxy.password`.
- **project-zot** `extensions.sync.urls[0]` → same URL.
- **Nexus Repository** "Docker (proxy)" remote URL → same URL, no auth.
- **JFrog Container Registry** Docker remote → same URL, no auth.
- **containerd registry mirror** (for kubelet image pulls) → `endpoint = ["http://127.0.0.1:5000"]` in a `containerdConfigPatches` block (kind config) or `hosts.toml`. Requires `hostNetwork: true` on the proxy pod so the node loopback works.

The Jenkins demo in [`../jenkins/`](../jenkins/) wires this for all five of the above via `setup.sh` — see `jenkins/mirrors/<tool>/deploy.sh` for examples.

## Endpoints

- `/v2/*` — proxied to `https://cgr.dev/v2/*`. The proxy strips any inbound `Authorization` header before forwarding so caller credentials never leak upstream.
- `/healthz` — `200 OK` only when a non-expired bearer is cached; `503` otherwise. Used by the Deployment's readiness probe.

## Operational notes

- **Cold start tolerance.** The proxy survives a missing SA token at startup — the background refresher retries with exponential backoff (up to 60s ceiling) and `/healthz` stays 503 until a token is cached. Once kubelet projects the token, the next refresh succeeds and the proxy starts serving.
- **STS outage tolerance.** The last-issued bearer keeps serving until its TTL (typically 1 hour). Cached layers on the downstream consumer (Harbor, distribution, etc.) continue to serve regardless.
- **Panic recovery.** The background refresh loop catches panics in the STS SDK and re-enters the backoff loop; the HTTP handler middleware catches panics in request paths. Either way, a single bad code path doesn't leave the proxy serving a stale token forever or wedge the listener.
- **Logging.** Structured JSON via `log/slog`. Each refresh logs `identity_prefix` (first 8 chars of the UIDP, not the full identifier), expiry, and TTL. Each inbound request logs method, path, status, duration, and remote host. The Chainguard bearer and SA JWT are never logged.
- **Error redaction.** SDK error strings can include bytes from the failing request/response, so the proxy logs only an error *class* (e.g. `sts_exchange`, `transport_not_ready`) by default. Pass `--verbose-errors` to log the raw error text — handy for debugging, but be aware it may include sensitive content depending on the SDK release.
- **Inbound limits.** Body cap 64 KiB, header cap 32 KiB, write/idle timeouts 60s. The proxy is read-only on its inbound side (no manifest pushes traverse it), so the body cap is generous.
- **Recreate, not Rolling.** The Deployment uses `strategy: Recreate` because `hostPort: 5000` is node-exclusive on a single-node cluster — a rolling update would deadlock waiting for the old pod to vacate the port.

## Pinning base-image digests

The Dockerfile ships **unpinned** — both `FROM` lines use floating `:latest-dev` and `:latest` tags — because cgr.dev digests are catalog-specific. The same tag has a different digest in `cgr.dev/chainguard/`, `cgr.dev/your-org.example.com/`, etc., so a shipped pin would break any user who builds against a different `CHAINGUARD_ORG`.

For reproducible builds, use [`scripts/pin-images.sh`](scripts/pin-images.sh). It resolves the current digests against the org you pass in and rewrites the `FROM` lines in place:

```sh
CHAINGUARD_ORG=chainguard ./scripts/pin-images.sh        # public catalog
CHAINGUARD_ORG=your-org.example.com ./scripts/pin-images.sh
git diff Dockerfile
```

The script needs `crane` on `PATH` (preferred — install from `cgr.dev/chainguard/crane`) and falls back to `docker buildx imagetools` if not. Commit the pinned Dockerfile. Re-run the script (or wire it into nightly CI) when you want to bump pins.

Switching `CHAINGUARD_ORG` later requires re-pinning — `docker build` will refuse to pull `cgr.dev/<new-org>/static:latest@<old-org's-digest>` because the digest doesn't exist in the new catalog.

## Building blocks

- [`github.com/google/go-containerregistry/pkg/v1/remote/transport`](https://pkg.go.dev/github.com/google/go-containerregistry/pkg/v1/remote/transport) — handles the OCI Bearer challenge dance against cgr.dev's auth realm.
- [`chainguard.dev/sdk/sts`](https://pkg.go.dev/chainguard.dev/sdk/sts) — Chainguard's STS client; `sts.New(issuer, audience, sts.WithIdentity(uidp)).Exchange(ctx, jwt)` returns `{AccessToken, RefreshToken, Expiry}`.

## License

Apache-2.0.
