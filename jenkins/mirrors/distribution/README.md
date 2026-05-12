# jenkins/mirrors/distribution — Optional distribution/distribution mirror

Stands up two instances of [distribution/distribution](https://github.com/distribution/distribution) (the reference OCI registry, formerly `docker/distribution`) inside the shared `jenkins-mirrors` kind cluster:

- **`distribution-proxy`** on host port **`5050`** — pull-through cache for `cgr.dev/${CHAINGUARD_ORG}/*`. Read-only; `delete: enabled: false`.
- **`distribution-hosted`** on host port **`5051`** — separate, regular registry that accepts anonymous push and pull, used as the demo's push target in place of `ttl.sh`.

Both deployments share one image (`cgr.dev/${CHAINGUARD_ORG}/distribution:3` by default) but are configured by different ConfigMaps. Storage is `emptyDir` in both — adequate for a demo, wiped on teardown.

## When you'd want this

distribution is the reference implementation of the OCI distribution-spec. Picking it (instead of Harbor, zot, Nexus, or JCR) gets you:

- **The smallest possible mirror** — a single Go binary, no UI, no database. Two pods cover both pull-through and push.
- **No long-lived credentials anywhere** — the proxy talks to `cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000`, which holds a projected k8s ServiceAccount JWT, exchanges it at Chainguard's STS for a short-lived registry bearer, and injects it on every outbound request to cgr.dev. The proxy's `proxy.username`/`proxy.password` fields are deliberately empty — auth happens upstream of distribution, in the cgr-oidc-proxy.
- **A demo-able push target** — pipelines push built artifacts to `localhost:5051/library/<image>:<tag>` and they persist (until teardown).

## Architecture

```
                    ┌─ host ──────────────────────────────────────┐
                    │                                             │
                    │  kind cluster (jenkins-mirrors)             │
   docker pull      │   ┌────────────────────────────────────┐    │
   localhost:5050   │   │ distribution-proxy   :5000 (NodePort 30050 -> host 5050)
   ───────────────▶ │   │   │                                │    │
                    │   │   ▼  proxy.remoteurl               │    │      cgr.dev
                    │   │  cgr-oidc-proxy ───────────────────┼────┼──▶
                    │   │   ▲ (projected SA JWT exchanged    │    │
                    │   │   │  at Chainguard STS for         │    │
                    │   │   │  short-lived bearer)           │    │
                    │   │                                    │    │
   docker push      │   │ distribution-hosted  :5000 (NodePort 30051 -> host 5051)
   localhost:5051   │   │   (anonymous push/pull, no proxy)  │    │
   ───────────────▶ │   └────────────────────────────────────┘    │
                    │                                             │
                    └─────────────────────────────────────────────┘
```

All distribution pods run in the `mirror-distribution` namespace; the cgr-oidc-proxy in its own `cgr-oidc-proxy` namespace (shared with any other mirror tool). The kind cluster's containerd is configured (`../_common/kind/config.yaml`) to mirror `cgr.dev` to the proxy on `127.0.0.1:5000`, so Kubernetes itself also pulls through it.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | One-shot: sources the shared bootstrap (kind + JWKS + chainguard_identity + cgr-oidc-proxy), then renders + applies the proxy and hosted manifests. Idempotent. Driven by env vars. |
| [`teardown.sh`](teardown.sh) | `kind delete cluster --name jenkins-mirrors`. |
| [`k8s/proxy/`](k8s/proxy/) | ConfigMap, Deployment template, Service for the pull-through proxy registry. |
| [`k8s/hosted/`](k8s/hosted/) | ConfigMap, Deployment template, Service for the hosted (push target) registry. |
| [`../_common/bootstrap.sh`](../_common/bootstrap.sh) | Shared bootstrap library: kind + namespaces + JWKS + stage-1 terraform + cgr-oidc-proxy. |
| [`../_common/kind/config.yaml`](../_common/kind/config.yaml) | Shared kind cluster definition: NodePort mappings 30050/30051 to host ports 5050/5051. |
| [`../../cgr-oidc-proxy/`](../../cgr-oidc-proxy/) | The OIDC-fronted reverse proxy. Shared. |

## Direct invocation (for debugging)

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into distribution mode. To run it by hand:

```sh
export CHAINGUARD_ORG=your-org-here   # whichever org owns the catalog
./deploy.sh
```

You'll need `chainctl` already authenticated against the Chainguard org so the terraform `chainguard` provider can create the proxy's identity.

URLs after deploy:

- Pull through cgr.dev: `localhost:5050/${CHAINGUARD_ORG}/<image>:<tag>` (e.g. `localhost:5050/your-org.example.com/python:3.14`)
- Push hosted target:   `localhost:5051/<image>:<tag>`            (e.g. `localhost:5051/library/pytest:3-14`)

Tear down with `./teardown.sh` (drops the whole shared kind cluster).

## Gotchas

- **Two registries, two ports.** The proxy and the hosted instance are *separate* deployments with separate storage. A pull from `localhost:5050/foo/bar` does **not** see anything pushed to `localhost:5051/foo/bar`. distribution does not have Harbor's "group repo" concept that combines proxy + hosted under one URL — if you need that, pick Harbor, Nexus, or JCR.
- **The proxy is read-only.** `storage.delete.enabled` is `false` and pushes against `localhost:5050` will get HTTP 405. distribution's proxy mode is by design pull-only.
- **`proxy.<image>` URL shape mirrors the upstream.** `proxy.remoteurl` is `http://cgr-oidc-proxy:5000`, which strips and re-injects the host header upstream against `cgr.dev`. cgr.dev's repos are namespaced as `<org>/<image>`, so to pull `cgr.dev/your-org/python:3.14` through this proxy you ask for `localhost:5050/your-org/python:3.14`.
- **No persistent storage.** Both registries store layers on `emptyDir`. A pod restart wipes them. That's fine for the demo — `setup.sh`'s pipelines push fresh artifacts each run.
- **`cgr.dev/${CHAINGUARD_ORG}/distribution:3`** must exist in your Chainguard org. If it doesn't (e.g. you're on a Starter tier with a limited catalog), set `DISTRIBUTION_IMAGE=registry:3.1.1` to fall back to Docker Hub.
