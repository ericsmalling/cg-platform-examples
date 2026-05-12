# jenkins/mirrors/jcr — Optional JFrog Container Registry pull-through cache

Stands up a [JFrog Container Registry (JCR)](https://jfrog.com/container-registry/) instance in the shared local `kind` cluster, configured as a **pull-through cache** for `cgr.dev/${CHAINGUARD_ORG}/*` and a **push target** for the demo's OCI-image pipelines.

JCR is JFrog's free, Docker-capable tier of Artifactory.

> **License caveat — non-commercial use only.** JCR is licensed for free non-commercial / evaluation use. Do **not** deploy this in production or for commercial purposes without a paid Artifactory license. This demo exists purely to illustrate the OCI-mirror pattern.

## Architecture

JCR runs as a single Deployment in the `mirror-jcr` namespace, backed by a 5 GiB PVC at `/var/opt/jfrog/artifactory`. It uses the embedded Derby database (no external Postgres). Like the other mirror tools, JCR pulls from `cgr.dev` via the in-cluster `cgr-oidc-proxy` Service — no long-lived pull token lives anywhere on disk.

JCR addresses Docker repos by **path** on its single HTTP port (8082). The Service exposes that one container port under two NodePorts so the Docker port has its own host-side label:

| Host port | NodePort | Container port | Purpose |
|----------:|---------:|---------------:|---------|
| 8082 | 30082 | 8082 | UI / REST API |
| 5054 | 30054 | 8082 | Docker pull/push (same JCR endpoint, just routed under a different host port for clarity) |

Both NodePorts hit the same JCR HTTP listener; only the URL host port differs.

## Repo conventions

`bootstrap-repos.sh` creates three Docker repos via Artifactory's REST API:

| Repo key | Type | Purpose | Example URL |
|---|---|---|---|
| `cgr-proxy` | remote | Pull-through cache for `cgr.dev` (via `cgr-oidc-proxy`) | `localhost:5054/cgr-proxy/<org>/<image>:<tag>` |
| `library` | local | Hosted push target for built artifacts | `localhost:5054/library/<image>:<tag>` |
| `library-group` | virtual | Aggregates `library` + `cgr-proxy` for unified pull | `localhost:5054/library-group/<image>:<tag>` |

`PUT /artifactory/api/repositories/<key>` is idempotent — re-running `bootstrap-repos.sh` overwrites existing repo config rather than failing.

## Admin credentials

JCR ships with a well-known default admin password (`admin/password`) that the platform forces you to change on first UI/API access. `bootstrap-repos.sh` does this automatically: it changes the password to `admin` (the demo's stable value) on first run and persists it to:

```
/tmp/cgjenkins-home/.secrets/jcr/admin.password   (mode 600)
```

`cgLogin` and other demo tooling read this file to authenticate Docker pushes to the `library` repo.

## Files

| Path | Purpose |
|------|---------|
| [`deploy.sh`](deploy.sh) | One-shot: sources the shared bootstrap, applies `k8s/`, waits for the rollout, runs `bootstrap-repos.sh`. Idempotent. Driven by env vars. |
| [`teardown.sh`](teardown.sh) | `kind delete cluster --name jenkins-mirrors` + cleanup of the JCR secrets dir. |
| [`bootstrap-repos.sh`](bootstrap-repos.sh) | Port-forwards to JCR, changes the admin password if still default, persists it, and PUTs the three Docker repos. |
| [`k8s/pvc.yaml`](k8s/pvc.yaml) | 5 GiB RWO PVC at `/var/opt/jfrog/artifactory`. |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | JCR Deployment (`releases-docker.jfrog.io/jfrog/artifactory-jcr:latest`) with embedded Derby DB and slow-startup probes. |
| [`k8s/service.yaml`](k8s/service.yaml) | NodePort Service exposing JCR's port 8082 twice (UI on 30082→host 8082, Docker on 30054→host 5054). |
| [`../_common/bootstrap.sh`](../_common/bootstrap.sh) | Shared bootstrap library, sourced by `deploy.sh`. |
| [`../_common/kind/config.yaml`](../_common/kind/config.yaml) | Shared kind cluster definition with the JCR `extraPortMappings` already wired. |

## Direct invocation (for debugging)

The demo's top-level `setup.sh` calls `deploy.sh` automatically when you opt into JCR mode. To run it by hand:

```sh
export CHAINGUARD_ORG=your-org-here
./deploy.sh
```

You'll need `chainctl` already authenticated against the Chainguard org so the terraform `chainguard` provider can create the proxy's identity.

## Slow-startup caveat

JCR is JVM-based and considerably heavier than Nexus CE: a cold first start (fresh PVC, embedded Derby init, license acceptance) typically takes **4–5 minutes** before `/artifactory/api/system/ping` answers 200 OK. The Deployment's `startupProbe` and `livenessProbe` are sized for this — `deploy.sh` waits up to 15 minutes for the rollout. Re-deploys against an existing PVC are noticeably faster (~1 minute).

If you see `kubectl rollout status` time out, check `kubectl -n mirror-jcr logs deploy/jcr` for license / DB init progress before rerunning.

## Tear down

```sh
./teardown.sh
```

This deletes the shared kind cluster (used by all mirrors) and removes `/tmp/cgjenkins-home/.secrets/jcr/`.
