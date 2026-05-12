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
  1. Tear down the shared mirrors kind cluster (if running).
  2. Run \`terraform destroy\` in iac/ (releases the Chainguard assumed identity, if any).
  3. Stop and remove the Jenkins controller container.
  4. Remove /tmp/cgjenkins-home (needs sudo).
  5. Remove .secrets/, shared-libraries/cg-images/IDENTITY, the captured
     kind-cluster JWKS, and the local Terraform state files in iac/,
     mirrors/_common/terraform/, and mirrors/harbor/terraform/.
$( [[ "$WIPE_ENV" == "true" ]] && echo "  6. Remove .env." )
EOF
echo
read -rp "Continue? [y/N]: " ans
[[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# Source .env if present (for ORG / settings that affect cleanup).
[[ -f .env ]] && { set -a; source .env; set +a; } || true

echo "==> 1/5 Tearing down shared mirrors kind cluster (if any)..."
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

echo "==> 2/5 Releasing Chainguard assumed identity (if Terraform state present)..."
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

echo "==> 3/5 Stopping Jenkins (docker compose down)..."
docker compose down --rmi local --remove-orphans 2>&1 | tail -5

echo "==> 4/5 Removing /tmp/cgjenkins-home..."
# On macOS + OrbStack the bind-mount is owned by the host user (no sudo).
# On Linux it may be owned by uid 1000 from inside the container, which maps
# to a different host user — fall back to sudo only when plain rm fails.
if ! rm -rf /tmp/cgjenkins-home 2>/dev/null; then
  echo "    Plain rm failed, retrying with sudo..."
  sudo rm -rf /tmp/cgjenkins-home
fi

echo "==> 5/5 Cleaning generated files..."
rm -rf .secrets
rm -f  shared-libraries/cg-images/IDENTITY
rm -rf iac/.terraform iac/terraform.tfstate iac/terraform.tfstate.backup iac/jenkins-jwks.json
# Stage 1 (shared chainguard_identity + rolebinding) state lives under
# mirrors/_common/terraform/. The captured kind JWKS sits next to it.
rm -rf mirrors/_common/terraform/.terraform mirrors/_common/terraform/terraform.tfstate mirrors/_common/terraform/terraform.tfstate.backup mirrors/_common/terraform/terraform.tfvars mirrors/_common/terraform/k8s-jwks.json mirrors/_common/terraform/.terraform.lock.hcl
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
