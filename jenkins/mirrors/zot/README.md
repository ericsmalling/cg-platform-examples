# jenkins/mirrors/zot — Optional project-zot pull-through cache + push target

Stands up a single [zot](https://zotregistry.dev/) registry in the shared `jenkins-mirrors` kind cluster, configured as both a **pull-through cache** for `cgr.dev/${CHAINGUARD_ORG}/*` and a **hosted registry** for pipeline pushes. One Deployment, one Service, one config file — zot's sync extension and its native hosted-storage path coexist on the same instance.

## When you'd want this

The default demo pulls Chainguard images directly from `cgr.dev/$CHAINGUARD_ORG`. Picking zot as the mirror tool replaces that with a local cache:

- **Smallest, simplest registry** of the four mirror options. Single Go binary, no database, no init containers, no Helm chart.
- **Anonymous pulls** for the demo — no auth on either the sync side (zot doesn't need credentials, since `cgr-oidc-proxy` injects them upstream) or the client side (`docker pull localhost:5052/...` works without a login).
- **Hosted pushes on the same port** — pipelines can target `localhost:5052/library/<image>:<tag>` without standing up a separate registry.
- **No long-lived Chainguard credentials anywhere** — sync goes through the shared in-cluster `cgr-oidc-proxy`, which mints short-lived bearers from a projected k8s ServiceAccount JWT.

## Architecture

```
                       ┌─ host ────────────────────────────────────────┐
                       │                                               │
                       │  kind cluster (jenkins-mirrors)               │
   docker pull         │   ┌──────────────────────────────────────┐    │
   localhost:5052/...  │   │  zot :5000  (NodePort 30052)         │    │
   ──────────────────▶ │   │   │                                  │    │
                       │   │   │ extensions.sync (onDemand)       │    │
                       │   │   ▼                                  │    │
                       │   │  cgr-oidc-proxy :5000 ───────────────┼────┼──▶ cgr.dev
                       │   │   ▲ (projected SA JWT                │    │
                       │   │   │  exchanged at Chainguard STS     │    │
                       │   │   │  for short-lived bearer)         │    │
                       │   └──────────────────────────────────────┘    │
                       │                                               │
                       └───────────────────────────────────────────────┘
```

zot runs in the `mirror-zot` namespace; the cgr-oidc-proxy in its own `cgr-oidc-proxy` namespace (shared with any other mirror tool). Storage is an `emptyDir` — for the demo we don't need persistence; teardown wipes the kind cluster and the cache with it.

## URL conventions

| Operation | URL |
|---|---|
| Pull (synced upstream) | `localhost:5052/<image>:<tag>` |
| Pull (synced upstream, in-cluster) | `zot.mirror-zot.svc.cluster.local:5000/<image>:<tag>` |
| Push (hosted only) | `localhost:5052/library/<image>:<tag>` |

The sync prefix is `${CHAINGUARD_ORG}/**` with `stripPrefix: true`, so a request for `localhost:5052/python:3.14` causes zot to fetch `cgr.dev/${CHAINGUARD_ORG}/python:3.14` (via the proxy) and serve it locally with the org segment dropped. Anything under `library/` doesn't match the sync prefix, so it's treated as plain hosted storage and accepts pushes.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | One-shot: sources the shared bootstrap (kind + JWKS + chainguard_identity + cgr-oidc-proxy), then renders the ConfigMap and applies the zot Deployment + Service. Idempotent. Driven by env vars. |
| [`teardown.sh`](teardown.sh) | `kind delete cluster --name jenkins-mirrors`. |
| [`k8s/configmap.yaml.template`](k8s/configmap.yaml.template) | zot `config.json` parameterized on `${CHAINGUARD_ORG}` (becomes the sync prefix). |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | One-replica Deployment running `ghcr.io/project-zot/zot-linux-amd64:v2.1.13` as UID 10001 with `/v2/` liveness/readiness probes. |
| [`k8s/service.yaml`](k8s/service.yaml) | NodePort Service: `nodePort: 30052` → host port 5052 via the shared kind config. |
| [`../_common/bootstrap.sh`](../_common/bootstrap.sh) | Shared bootstrap library: kind cluster + namespaces + JWKS capture + stage-1 terraform + cgr-oidc-proxy build/deploy. |
| [`../_common/kind/config.yaml`](../_common/kind/config.yaml) | Shared kind cluster definition; the 30052→5052 mapping for zot lives here. |
| [`../../cgr-oidc-proxy/`](../../cgr-oidc-proxy/) | The OIDC-fronted reverse proxy: small Go binary, Dockerfile, k8s Deployment/Service/ServiceAccount. Shared. |

## Direct invocation (for debugging)

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into zot mode. To run it by hand:

```sh
export CHAINGUARD_ORG=your-org-here
./deploy.sh
```

You'll need `chainctl` already authenticated against the Chainguard org so the shared stage-1 terraform `chainguard` provider can create the proxy's identity.

Tear down with `./teardown.sh`.

## Gotchas

- **Sync is on-demand, not pre-pulled.** The first request for an image incurs a cold-cache pull through the proxy. Subsequent pulls are local.
- **`stripPrefix: true` means the org segment is invisible locally.** `cgr.dev/myorg.example.com/python:3.14` is `localhost:5052/python:3.14`, not `localhost:5052/myorg.example.com/python:3.14`. This is deliberate — pipelines reference `${PULL_REGISTRY}/<image>` without knowing the org name.
- **`library/` is reserved for pushes.** Don't push to a path that overlaps with the sync prefix; zot won't refuse the push, but you'll get confusing behavior when sync and hosted content collide on the same name.
- **No auth for the demo.** The htpasswd extension is disabled. Don't expose this zot to anything outside the host.
- **emptyDir storage.** Restarting the zot pod loses the cache. For the demo this is fine (and intentional — teardown should leave nothing behind); for any longer-lived setup, swap to a PVC.
