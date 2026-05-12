#!/usr/bin/env bash
# Tear down everything setup.sh + the demo created:
#   - Harbor kind cluster (if present)
#   - Chainguard assumed identity (terraform destroy on iac/, if state present)
#   - Jenkins controller container + image
#   - JENKINS_HOME bind-mount at /tmp/cgjenkins-home (needs sudo)
#   - cosign keys (under /tmp/cgjenkins-home/.secrets/, wiped with cgjenkins-home)
#   - .secrets/, IDENTITY file, terraform state files, captured k8s JWKS
#
# Leaves .env in place (so re-running setup.sh remembers your CHAINGUARD_ORG
# choice). Pass --wipe-env to remove that too.
set -euo pipefail

cd "$(dirname "$0")"

WIPE_ENV=false
for arg in "$@"; do
  case "$arg" in
    --wipe-env) WIPE_ENV=true ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

cat <<EOF
This will:
  1. Delete any chainctl pull tokens minted by setup.sh in pull-token mode
     (cached under mirrors/_common/.pull-tokens/).
  2. Tear down the shared mirrors kind cluster (if running).
  3. Run \`terraform destroy\` in iac/ (releases the Chainguard assumed identity, if any).
  4. Stop and remove the Jenkins controller container.
  5. Remove /tmp/cgjenkins-home (needs sudo).
  6. Remove .secrets/, shared-libraries/cg-images/IDENTITY, the captured
     kind-cluster JWKS, and the local Terraform state files in iac/,
     mirrors/_common/terraform/, and mirrors/harbor/terraform/.
$( [[ "$WIPE_ENV" == "true" ]] && echo "  7. Remove .env." )
EOF
echo
read -rp "Continue? [y/N]: " ans
[[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# Source .env if present (for ORG / settings that affect cleanup).
[[ -f .env ]] && { set -a; source .env; set +a; } || true

echo "==> 1/6 Deleting chainctl pull tokens (if any)..."
# Pull tokens minted in AUTH_MODE=pull-token are cached under
# mirrors/_common/.pull-tokens/<tool>.json. Each file is the full chainctl
# JSON response, including identity_id (the Chainguard identity UIDP we
# need to pass to `chainctl auth pull-token delete`). If chainctl isn't
# installed or the user isn't logged in, we still remove the cache file
# but leave the upstream token to time out on its own — and warn so the
# user can clean it up manually.
PULL_TOKEN_DIR="mirrors/_common/.pull-tokens"
if compgen -G "$PULL_TOKEN_DIR/*.json" >/dev/null; then
  if ! command -v chainctl >/dev/null 2>&1; then
    echo "    SKIPPING delete: chainctl not in PATH. Tokens will linger until TTL expiry."
    echo "    Cached files: $PULL_TOKEN_DIR/*.json"
  else
    for tf in "$PULL_TOKEN_DIR"/*.json; do
      [[ -e "$tf" ]] || continue
      # The pull token IS a chainguard identity; chainctl tracks it by `id`
      # (a "<org-uidp>/<id>" pair from the create response, also the form
      # accepted by `chainctl iam identities delete`). We also keep
      # identity_id (the same UIDP, no slash) and name for diagnostics.
      delete_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$tf" 2>/dev/null || true)"
      if [[ -z "$delete_id" ]]; then
        # Older cache files may not have `id` — fall back to identity_id.
        delete_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("identity_id",""))' "$tf" 2>/dev/null || true)"
      fi
      name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$tf" 2>/dev/null || true)"
      if [[ -z "$delete_id" ]]; then
        echo "    WARN: $tf has no id/identity_id; can't delete via chainctl. Leaving it for manual cleanup."
        continue
      fi
      echo "    Deleting pull token ${name:-?} ($delete_id)..."
      # `chainctl auth pull-token` exposes only create + list — pull tokens
      # are deleted as identities. The command prompts for confirmation
      # interactively (no --yes flag in current chainctl), so feed `y`
      # via stdin. We tolerate failure (token may have already expired
      # via TTL) so one stale entry doesn't block the rest of teardown.
      printf 'y\n' | chainctl iam identities delete "$delete_id" 2>&1 | sed 's/^/      /' || \
        echo "      (delete failed — token may have already expired or chainctl syntax differs)"
    done
  fi
  rm -rf "$PULL_TOKEN_DIR"
fi

echo "==> 2/6 Tearing down shared mirrors kind cluster (if any)..."
# The kind cluster is shared across all mirror tools (jenkins-mirrors).
# Any of the per-mirror teardown.sh scripts can delete it — they all
# target the same cluster name. We invoke whichever exists; harbor's is
# the canonical fallback.
TORE_DOWN=false
for tool in "${MIRROR_TOOL:-}" harbor distribution zot nexus-ce jcr; do
  if [[ -n "$tool" && -x "mirrors/$tool/teardown.sh" ]]; then
    "mirrors/$tool/teardown.sh"
    TORE_DOWN=true
    break
  fi
done
if [[ "$TORE_DOWN" == "false" ]]; then
  # Last resort: delete the cluster directly.
  command -v kind >/dev/null 2>&1 && kind delete cluster --name "${KIND_CLUSTER_NAME:-jenkins-mirrors}" 2>&1 || true
fi

echo "==> 3/6 Releasing Chainguard assumed identity (if Terraform state present)..."
if [[ -f iac/terraform.tfstate ]]; then
  if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
    echo "    SKIPPING: CHAINGUARD_ORG not set in .env, can't run terraform destroy."
    echo "    The identity will linger; clean it up manually with chainctl iam identities delete."
  else
    ( cd iac && terraform destroy -auto-approve \
        -var="chainguard_group_name=${CHAINGUARD_ORG}" \
        -var="jenkins_issuer_url=${JENKINS_OIDC_ISSUER:-https://localhost:8080/oidc}" || true )
  fi
fi

echo "==> 4/6 Stopping Jenkins (docker compose down)..."
docker compose down --rmi local --remove-orphans 2>&1 | tail -5

echo "==> 5/6 Removing /tmp/cgjenkins-home..."
# On macOS + OrbStack the bind-mount is owned by the host user (no sudo).
# On Linux it may be owned by uid 1000 from inside the container, which maps
# to a different host user — fall back to sudo only when plain rm fails.
if ! rm -rf /tmp/cgjenkins-home 2>/dev/null; then
  echo "    Plain rm failed, retrying with sudo..."
  sudo rm -rf /tmp/cgjenkins-home
fi

echo "==> 6/6 Cleaning generated files..."
rm -rf .secrets
rm -f  shared-libraries/cg-images/IDENTITY
rm -rf iac/.terraform iac/terraform.tfstate iac/terraform.tfstate.backup iac/jenkins-jwks.json
# Stage 1 (shared chainguard_identity + rolebinding) state lives under
# mirrors/_common/terraform/. The captured kind JWKS sits next to it.
rm -rf mirrors/_common/terraform/.terraform mirrors/_common/terraform/terraform.tfstate mirrors/_common/terraform/terraform.tfstate.backup mirrors/_common/terraform/terraform.tfvars mirrors/_common/terraform/k8s-jwks.json mirrors/_common/terraform/.terraform.lock.hcl
# Rendered kind config (the .template lives next to it in git).
rm -f  mirrors/_common/kind/config.yaml
# Stage 2 (Harbor-specific harbor_registry + harbor_project) state lives
# under mirrors/harbor/terraform/. No tfvars here — stage 2 takes no inputs.
rm -rf mirrors/harbor/terraform/.terraform mirrors/harbor/terraform/terraform.tfstate mirrors/harbor/terraform/terraform.tfstate.backup mirrors/harbor/terraform/.terraform.lock.hcl
rm -f  mirrors/harbor/cg/helm/values.yaml mirrors/harbor/cg/manifests/deploy-ingress-nginx.yaml

if [[ "$WIPE_ENV" == "true" ]]; then
  rm -f .env
  echo "    Removed .env."
fi

echo
echo "==> Done. Re-run ./setup.sh to bootstrap from scratch."
