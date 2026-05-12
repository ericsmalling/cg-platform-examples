#!/usr/bin/env bash
# Integration test harness for the OCI-mirror demos. For each combination of
# (mirror tool, auth mode) it does:
#
#   1. ./teardown.sh (yes-y'd) to start from a clean kind cluster.
#   2. ./setup.sh with the right answers piped via stdin so the run is
#      non-interactive.
#   3. Post-setup verification: pod readiness, regcred Secret + pull-token
#      cache presence/absence (per auth mode), proxy Deployment readiness
#      (proxy mode only), and a registry-manifest probe through the
#      mirror's host-port endpoint to prove the upstream flow is wired.
#   4. ./teardown.sh + a follow-up check that the cached pull token (if
#      any) was deleted from Chainguard.
#
# Output: a markdown matrix to stdout, plus per-test stdout+stderr logs
# under tests/.logs/<mirror>-<mode>.log (gitignored). Exit code 0 iff
# every requested combination passed.
#
# CLI:
#   ./tests/run-mirror-matrix.sh                  # all 10 combinations
#   ./tests/run-mirror-matrix.sh harbor           # both modes for harbor
#   ./tests/run-mirror-matrix.sh harbor proxy     # single combo
#   ./tests/run-mirror-matrix.sh --skip-teardown  # leave the last test's
#                                                   cluster up for poking
#
# Env:
#   CHAINGUARD_ORG    required; read from ../.env if not exported
#   PULL_TOKEN_TTL    default 1h — short so leaked tokens expire quickly
#   TEST_IMAGE        catalog image:tag probed through every mirror;
#                     default cgr.dev/${ORG}/crane:latest-dev (small,
#                     present in most orgs that have basic Chainguard
#                     access)
#   SKIP_PREFLIGHT    forwarded to setup.sh; default unset (preflight on)

set -u  # not -e: per-test failures are expected; the harness tracks them itself
set -o pipefail

# ---- Argument parsing ---------------------------------------------------

SKIP_FINAL_TEARDOWN=false
FILTER_MIRROR=""
FILTER_MODE=""
for arg in "$@"; do
  case "$arg" in
    --skip-teardown) SKIP_FINAL_TEARDOWN=true ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      if [[ -z "$FILTER_MIRROR" ]]; then
        FILTER_MIRROR="$arg"
      elif [[ -z "$FILTER_MODE" ]]; then
        FILTER_MODE="$arg"
      else
        echo "too many positional args: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

# Resolve script dir → repo root for the demo (jenkins/).
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
cd "$DEMO_DIR"

# Pick up CHAINGUARD_ORG from .env if not exported.
if [[ -z "${CHAINGUARD_ORG:-}" ]] && [[ -f .env ]]; then
  CHAINGUARD_ORG="$(grep -E '^CHAINGUARD_ORG=' .env | head -1 | cut -d= -f2-)"
  CHAINGUARD_ORG="${CHAINGUARD_ORG//\"/}"
fi
if [[ -z "${CHAINGUARD_ORG:-}" ]]; then
  echo "ERROR: CHAINGUARD_ORG not set (export it or put it in .env)" >&2
  exit 2
fi
export CHAINGUARD_ORG

PULL_TOKEN_TTL="${PULL_TOKEN_TTL:-1h}"
TEST_IMAGE="${TEST_IMAGE:-crane:latest-dev}"

LOG_DIR="$TESTS_DIR/.logs"
mkdir -p "$LOG_DIR"

# ---- Combinations -------------------------------------------------------
# Each entry: <mirror>:<auth>:<setup.sh stdin>:<verify_endpoint_url_path>
#
# stdin is the full sequence of answers; trailing \n included. Order:
#   1. mirror menu (1..6)
#   2. auth mode menu (1..2)
#   3. TTL prompt (only in pull-token mode)
#   4. harbor-push prompt (only when mirror=harbor)
#
# verify_endpoint_url_path is the path component appended to
# "http(s)://<host>:<port>" to probe a registry manifest GET. Host/port
# vary per mirror and are baked into the verify function below.

mirror_to_num() {
  case "$1" in
    harbor)       echo 2 ;;
    distribution) echo 3 ;;
    zot)          echo 4 ;;
    nexus-ce)     echo 5 ;;
    jcr)          echo 6 ;;
    *) echo "unknown mirror: $1" >&2; exit 2 ;;
  esac
}

auth_to_num() {
  case "$1" in
    proxy)      echo 1 ;;
    pull-token) echo 2 ;;
    *) echo "unknown auth mode: $1" >&2; exit 2 ;;
  esac
}

# Build the stdin payload to feed into setup.sh for (mirror, mode).
build_stdin() {
  local mirror="$1" mode="$2"
  local m a
  m="$(mirror_to_num "$mirror")"
  a="$(auth_to_num "$mode")"
  printf '%s\n%s\n' "$m" "$a"
  if [[ "$mode" == "pull-token" ]]; then
    printf '%s\n' "$PULL_TOKEN_TTL"
  fi
  if [[ "$mirror" == "harbor" ]]; then
    printf 'y\n'
  fi
}

# (mirror, scheme, hostport, path-template) — TAG is appended at probe time.
# Path templates use $ORG and $IMG_PATH placeholders we expand later.
probe_for_mirror() {
  local mirror="$1"
  case "$mirror" in
    harbor)       echo "http localhost     /v2/cgr-proxy/${CHAINGUARD_ORG}/{IMG}/manifests/{TAG}" ;;
    distribution) echo "http localhost:5050 /v2/${CHAINGUARD_ORG}/{IMG}/manifests/{TAG}" ;;
    # zot's sync rule has stripPrefix:true on "${ORG}/**", so the path on zot
    # drops the org segment.
    zot)          echo "http localhost:5052 /v2/{IMG}/manifests/{TAG}" ;;
    # Nexus CE rewrites docker proxy paths to its upstream remote, which is
    # either cgr-oidc-proxy (rewrites itself) or https://cgr.dev/${ORG} in
    # pull-token mode. Either way, the client-side path drops the org.
    nexus-ce)     echo "http localhost:5053 /v2/{IMG}/manifests/{TAG}" ;;
    # JCR exposes a path-style docker repo: /artifactory/api/docker/cgr-proxy/v2/.
    jcr)          echo "http localhost:5054 /v2/cgr-proxy/{IMG}/manifests/{TAG}" ;;
  esac
}

# Split TEST_IMAGE into image + tag for path-template substitution.
TEST_IMG="${TEST_IMAGE%:*}"
TEST_TAG="${TEST_IMAGE##*:}"
if [[ "$TEST_IMG" == "$TEST_TAG" ]]; then
  echo "ERROR: TEST_IMAGE must be image:tag (got '$TEST_IMAGE')" >&2
  exit 2
fi

# ---- Verification ------------------------------------------------------

verify_setup() {
  local mirror="$1" mode="$2"
  local ns="mirror-$mirror"
  local notes=""

  # Cluster present?
  if ! kind get clusters 2>/dev/null | grep -qx jenkins-mirrors; then
    echo "FAIL: kind cluster 'jenkins-mirrors' not present"
    return 1
  fi

  # Mirror's namespace exists?
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace '$ns' missing"
    return 1
  fi

  case "$mode" in
    proxy)
      if ! kubectl get deploy -n cgr-oidc-proxy cgr-oidc-proxy >/dev/null 2>&1; then
        echo "FAIL: proxy mode but cgr-oidc-proxy Deployment missing"
        return 1
      fi
      local ready
      ready="$(kubectl get deploy -n cgr-oidc-proxy cgr-oidc-proxy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
      if [[ "${ready:-0}" -lt 1 ]]; then
        echo "FAIL: cgr-oidc-proxy has no Ready replicas"
        return 1
      fi
      if kubectl get secret -n "$ns" regcred >/dev/null 2>&1; then
        notes+="regcred unexpectedly present in $ns (proxy mode); "
      fi
      if [[ -f "mirrors/_common/.pull-tokens/$mirror.json" ]]; then
        notes+="pull-token cache unexpectedly present (proxy mode); "
      fi
      ;;
    pull-token)
      if kubectl get deploy -n cgr-oidc-proxy cgr-oidc-proxy >/dev/null 2>&1; then
        notes+="cgr-oidc-proxy Deployment unexpectedly present (pull-token mode); "
      fi
      if ! kubectl get secret -n "$ns" regcred >/dev/null 2>&1; then
        echo "FAIL: pull-token mode but regcred Secret missing in $ns"
        return 1
      fi
      if [[ ! -f "mirrors/_common/.pull-tokens/$mirror.json" ]]; then
        echo "FAIL: pull-token cache file mirrors/_common/.pull-tokens/$mirror.json missing"
        return 1
      fi
      ;;
  esac

  # Mirror-specific Ready-pod check.
  case "$mirror" in
    harbor)
      kubectl -n "$ns" wait --for=condition=Available deploy/harbor-core --timeout=60s >/dev/null 2>&1 \
        || { echo "FAIL: harbor-core Deployment not Available"; return 1; }
      ;;
    distribution)
      kubectl -n "$ns" wait --for=condition=Available deploy/distribution-proxy --timeout=60s >/dev/null 2>&1 \
        || { echo "FAIL: distribution-proxy Deployment not Available"; return 1; }
      ;;
    zot)
      kubectl -n "$ns" wait --for=condition=Available deploy/zot --timeout=60s >/dev/null 2>&1 \
        || { echo "FAIL: zot Deployment not Available"; return 1; }
      ;;
    nexus-ce)
      kubectl -n "$ns" wait --for=condition=Available deploy/nexus-ce --timeout=60s >/dev/null 2>&1 \
        || { echo "FAIL: nexus-ce Deployment not Available"; return 1; }
      ;;
    jcr)
      kubectl -n "$ns" wait --for=condition=Available deploy/jcr --timeout=60s >/dev/null 2>&1 \
        || { echo "FAIL: jcr Deployment not Available"; return 1; }
      ;;
  esac

  # Probe the mirror's pull endpoint.
  read -r scheme hostport pathtpl <<<"$(probe_for_mirror "$mirror")"
  local path="${pathtpl//\{IMG\}/$TEST_IMG}"
  path="${path//\{TAG\}/$TEST_TAG}"
  local url="${scheme}://${hostport}${path}"

  # Some mirrors require Docker bearer auth even on the proxy cache (Nexus,
  # JCR). For those, anonymous pulls return 401 → 200 after an auto-issued
  # bearer. curl can't follow that flow without docker-cli logic, so we
  # accept either 200 OK or a 401 with WWW-Authenticate: Bearer as proof
  # the registry endpoint exists and is reachable. A 503/504/connection
  # refused is a hard fail.
  # -s (silent) but no -f (we want to capture 4xx as a valid HTTP response,
  # not a curl failure). On true network error curl exits non-zero and prints
  # only "000" from %{http_code}; the `|| echo` fallback keeps $code sane.
  #
  # Retry with backoff: host-port forwarding via kind takes a moment to
  # settle after `kubectl rollout status` returns, and proxy-mode upstream
  # warmup adds another second or two for the first fetch.
  local code=000 attempt
  for attempt in 1 2 3 4 5 6; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)"
    code="${code:-000}"
    case "$code" in
      200|401) break ;;
    esac
    sleep 5
  done
  case "$code" in
    200|401)
      notes+="probe ${url} → HTTP ${code}; "
      ;;
    000|5*)
      echo "FAIL: probe ${url} returned HTTP ${code} (mirror not serving)"
      [[ -n "$notes" ]] && echo "       notes: ${notes%; }"
      return 1
      ;;
    *)
      notes+="probe ${url} → HTTP ${code} (unexpected, treating as soft pass); "
      ;;
  esac

  echo "PASS${notes:+ — ${notes%; }}"
  return 0
}

# After teardown, verify the pull token was actually deleted from Chainguard.
verify_teardown() {
  local mirror="$1" mode="$2"

  if [[ -d mirrors/_common/.pull-tokens ]] && \
     find mirrors/_common/.pull-tokens -mindepth 1 2>/dev/null | grep -q .; then
    echo "FAIL: pull-token cache still has files after teardown"
    return 1
  fi
  if kind get clusters 2>/dev/null | grep -qx jenkins-mirrors; then
    echo "FAIL: kind cluster still present after teardown"
    return 1
  fi

  # Best-effort: confirm chainctl no longer lists the token. Only meaningful
  # in pull-token mode AND only when chainctl is available + authenticated.
  # The list response shape is {"items":[{name,id,...},...]} and chainctl
  # auto-appends " - registry" to the requested name when the token's
  # repository type is `oci` (the default) — both quirks need handling.
  if [[ "$mode" == "pull-token" ]] && command -v chainctl >/dev/null 2>&1; then
    local token_name="jenkins-mirror-$mirror"
    if chainctl auth pull-token list --parent="$CHAINGUARD_ORG" -o json 2>/dev/null \
         | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', []) if isinstance(data, dict) else data
target = sys.argv[1]
matches = [t for t in items if isinstance(t, dict) and t.get('name','').startswith(target)]
sys.exit(0 if not matches else 1)
" "$token_name"; then
      :
    else
      echo "FAIL: chainctl still lists pull-token '$token_name*' after teardown"
      return 1
    fi
  fi

  echo "PASS"
  return 0
}

# ---- Test runner --------------------------------------------------------

run_combo() {
  local mirror="$1" mode="$2"
  local log="$LOG_DIR/${mirror}-${mode}.log"
  : > "$log"

  echo
  echo "================================================================"
  echo "  $mirror / $mode"
  echo "================================================================"

  local setup_status verify_status teardown_status verify_msg teardown_msg

  # Step 1: clean teardown.
  echo "  [1/4] teardown (pre-test)..."
  if printf 'y\n' | ./teardown.sh >>"$log" 2>&1; then
    :
  else
    # Teardown of an empty environment is fine — only flag if a subsequent
    # step actually fails.
    :
  fi

  # Pre-pull setup.sh's base images via the docker daemon (which has the
  # cgr.dev credential helper). Workaround for a flake where `docker compose
  # build` via BuildKit occasionally fails to auth to cgr.dev with 401 even
  # though the daemon-side credential helper still works fine. Once the
  # images are in the local store, BuildKit resolves them locally and the
  # auth path doesn't get exercised. Failure here is non-fatal — setup.sh
  # will retry the pull itself.
  echo "  [1.5/4] pre-pulling base images..."
  # Jenkins Dockerfile + cgr-oidc-proxy Dockerfile base images. static:latest
  # is the cgr-oidc-proxy's runtime base — easy to miss because it's not
  # referenced from any Compose-built image.
  for img in docker-cli:29 chainctl:latest-dev jenkins:2-lts-jdk21-dev go:latest-dev static:latest; do
    docker pull "cgr.dev/${CHAINGUARD_ORG}/${img}" >>"$log" 2>&1 || true
  done

  # Step 2: setup.sh with piped stdin. Pipe build_stdin directly rather
  # than capturing in `$(...)` — command substitution strips trailing
  # newlines, which drops the terminator after the last `read` and trips
  # setup.sh's `set -e` on read-EOF.
  echo "  [2/4] setup ($mode)..."
  echo "    stdin: $(build_stdin "$mirror" "$mode" | tr '\n' '|')"
  if build_stdin "$mirror" "$mode" | ./setup.sh >>"$log" 2>&1; then
    setup_status="PASS"
  else
    setup_status="FAIL (exit $?)"
  fi
  echo "    setup: $setup_status"

  # Step 3: verify (only meaningful if setup passed).
  if [[ "$setup_status" == "PASS" ]]; then
    echo "  [3/4] verify..."
    verify_msg="$(verify_setup "$mirror" "$mode" 2>&1)"
    case "$verify_msg" in
      PASS*) verify_status="PASS" ;;
      *)     verify_status="FAIL" ;;
    esac
    echo "    verify: $verify_msg"
  else
    verify_status="SKIP"
    verify_msg="(skipped: setup failed)"
  fi

  # Step 4: teardown + verify token deletion.
  echo "  [4/4] teardown (post-test)..."
  if printf 'y\n' | ./teardown.sh >>"$log" 2>&1; then
    teardown_msg="$(verify_teardown "$mirror" "$mode" 2>&1)"
    case "$teardown_msg" in
      PASS*) teardown_status="PASS" ;;
      *)     teardown_status="FAIL" ;;
    esac
  else
    teardown_status="FAIL"
    teardown_msg="(teardown.sh exited non-zero)"
  fi
  echo "    teardown: $teardown_msg"

  # Append matrix row.
  printf '| %-12s | %-10s | %-6s | %-6s | %-8s | %s |\n' \
    "$mirror" "$mode" "$setup_status" "$verify_status" "$teardown_status" \
    "${verify_msg//|/\\|} / ${teardown_msg//|/\\|}" \
    >> "$RESULTS_TABLE"

  if [[ "$setup_status" == "PASS" && "$verify_status" == "PASS" && "$teardown_status" == "PASS" ]]; then
    return 0
  fi
  return 1
}

# ---- Main ---------------------------------------------------------------

ALL_MIRRORS=(harbor distribution zot nexus-ce jcr)
ALL_MODES=(proxy pull-token)

if [[ -n "$FILTER_MIRROR" ]]; then
  case "$FILTER_MIRROR" in
    harbor|distribution|zot|nexus-ce|jcr) MIRRORS=("$FILTER_MIRROR") ;;
    *) echo "unknown mirror filter: $FILTER_MIRROR" >&2; exit 2 ;;
  esac
else
  MIRRORS=("${ALL_MIRRORS[@]}")
fi

if [[ -n "$FILTER_MODE" ]]; then
  case "$FILTER_MODE" in
    proxy|pull-token) MODES=("$FILTER_MODE") ;;
    *) echo "unknown mode filter: $FILTER_MODE" >&2; exit 2 ;;
  esac
else
  MODES=("${ALL_MODES[@]}")
fi

RESULTS_TABLE="$(mktemp)"
trap 'rm -f "$RESULTS_TABLE"' EXIT

echo "Mirror matrix tests"
echo "  CHAINGUARD_ORG  = $CHAINGUARD_ORG"
echo "  PULL_TOKEN_TTL  = $PULL_TOKEN_TTL"
echo "  TEST_IMAGE      = $TEST_IMAGE"
echo "  combinations    = $((${#MIRRORS[@]} * ${#MODES[@]}))"
echo "  log dir         = $LOG_DIR"

FAILED=0
for mirror in "${MIRRORS[@]}"; do
  for mode in "${MODES[@]}"; do
    if ! run_combo "$mirror" "$mode"; then
      FAILED=$((FAILED + 1))
    fi
  done
done

echo
echo "================================================================"
echo "  Results"
echo "================================================================"
echo
printf '| %-12s | %-10s | %-6s | %-6s | %-8s | %s |\n' \
  "Mirror" "Mode" "Setup" "Verify" "Teardown" "Notes"
printf '| %-12s | %-10s | %-6s | %-6s | %-8s | %s |\n' \
  "------------" "----------" "------" "------" "--------" "-----"
cat "$RESULTS_TABLE"
echo

if (( FAILED > 0 )); then
  echo "FAIL: $FAILED combination(s) failed. See per-test logs under $LOG_DIR/"
  exit 1
fi
echo "All ${#MIRRORS[@]}×${#MODES[@]} combinations passed."

if [[ "$SKIP_FINAL_TEARDOWN" != "true" ]]; then
  # Already torn down by run_combo's step 4; nothing extra to do.
  :
fi
