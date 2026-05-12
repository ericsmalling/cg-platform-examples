# jenkins/mirrors/nexus-ce — Sonatype Nexus Repository 3 Community Edition

Stands up a single-pod [Nexus Repository 3 Community Edition](https://help.sonatype.com/en/sonatype-nexus-repository.html) instance in the shared `kind` cluster, configured as both a **pull-through cache** for `cgr.dev/${CHAINGUARD_ORG}/*` (via the `cgr-oidc-proxy` Deployment) and a **push target** for the demo's OCI-image pipelines.

## When you'd want this

Same trade-offs as the other mirror tools, plus: Nexus is the canonical "all-purpose artifact repo" for many enterprise installs (Maven, npm, PyPI, plus OCI), so seeing it work in the demo proves the OIDC-fronted proxy plays nicely with the registry many shops already run.

Nexus CE has a 3-pulls-per-minute rate limit and a 200K-component cap; both are well above what this demo exercises.

## Three docker repositories

Nexus models docker repos in three flavors that you compose:

| Repo | Type | Purpose |
|------|------|---------|
| `cgr-proxy`     | proxy   | Docker proxy of `http://cgr-oidc-proxy.cgr-oidc-proxy.svc.cluster.local:5000`. Caches `cgr.dev/${CHAINGUARD_ORG}/*` images. No upstream auth — the proxy itself injects the OIDC-derived bearer. |
| `library`       | hosted  | Push target. Built pipeline artifacts land here. |
| `library-group` | group   | Composes `library` + `cgr-proxy` behind a single docker connector on host port 5053. Pulls fall through to `library` first, then `cgr-proxy`; pushes route to `library` (the writable member). This is the endpoint clients hit. |

## URL conventions

```
docker pull localhost:5053/library-group/<image>:<tag>   # unified pull
docker pull localhost:5053/cgr-proxy/<image>:<tag>       # explicit proxy path (also works)
docker push localhost:5053/library/<image>:<tag>         # explicit hosted (writable)
docker push localhost:5053/library-group/<image>:<tag>   # group push, routes to library
```

The Nexus web UI lives at <http://localhost:8081> (no TLS — plain HTTP for the demo). Default admin credentials after bootstrap: `admin` / `admin`. The bootstrap script writes the admin password to `/tmp/cgjenkins-home/.secrets/nexus-ce/admin.password` (mode 600) so `cgLogin.groovy` can pick it up.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh)                 | Sources `../_common/bootstrap.sh`, applies `k8s/`, then runs `bootstrap-repos.sh`. Idempotent. |
| [`teardown.sh`](teardown.sh)             | Deletes the shared kind cluster + the host-side admin-password secret dir. |
| [`bootstrap-repos.sh`](bootstrap-repos.sh) | Host-side: port-forwards to the Nexus pod, rotates the first-run admin password to the demo value, enables the Docker Bearer Token realm, and creates the `cgr-proxy` / `library` / `library-group` repos via the REST API. Idempotent — "already exists" responses are ignored. |
| [`k8s/pvc.yaml`](k8s/pvc.yaml)           | 5 GiB ReadWriteOnce PVC for `/nexus-data`. |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | `sonatype/nexus3:3.91.1`, 1 CPU / 2 GiB request, generous startupProbe (Nexus is slow to come up). |
| [`k8s/service.yaml`](k8s/service.yaml)   | NodePort: `8081 -> 30081` (UI/REST), `5053 -> 30053` (docker connector). Mapped to host ports 8081/5053 by `../_common/kind/config.yaml`. |

## Slow startup caveat

The `sonatype/nexus3:3.91.1` image is ~300 MB and takes 2–3 minutes from container start to a healthy `/service/rest/v1/status`. The Deployment's `startupProbe` allows up to ~7.5 minutes (60s initial + 30 × 15s) before the kubelet starts marking the container Unhealthy; the `livenessProbe` only kicks in after that. The `deploy.sh` rollout-status timeout is 10 minutes for the same reason. If you see `kubectl rollout status` time out, check `kubectl -n mirror-nexus-ce logs deploy/nexus-ce` — usually it's still booting.

## Why a host-side script for `bootstrap-repos.sh`?

The Nexus image doesn't ship `curl`, and building a separate tools image just to run a handful of REST calls would add another Chainguard rebuild to the demo. A host-side `kubectl port-forward` + `curl` is simpler, has no extra image, and reuses the tools the rest of the demo already requires. The trade-off is that running this on a CI agent without `kubectl`/`curl`/`jq` won't work — but those are the same prerequisites as `setup.sh` itself.

## Direct invocation

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into Nexus mode. To run it by hand:

```sh
export CHAINGUARD_ORG=your-org-here
./deploy.sh
```

Tear down with `./teardown.sh`.
