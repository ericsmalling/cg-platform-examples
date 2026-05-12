// vars/cgLogin.groovy
//
// Sets up the controller's docker config so the rest of the pipeline can
// pull (and optionally push) Chainguard images. Behavior depends on which
// mirror tool was picked at setup.sh time, via env.MIRROR_TOOL:
//
//   none — direct cgr.dev with Jenkins OIDC chainctl per build.
//          Exchanges the Jenkins-issued OIDC token for a short-lived
//          Chainguard session via `chainctl auth login` + `chainctl auth
//          configure-docker`. Push targets like ttl.sh don't need creds.
//
//   harbor — Harbor as pull-through proxy. Pulls go anonymously through
//          Harbor's public cgr-proxy project. Pushes either go to ttl.sh
//          (Mode B; no creds) or to Harbor's library project (Mode C;
//          admin/Harbor12345).
//
//   distribution / zot — both run anonymously: pulls and pushes need no
//          credentials. The Auth stage is effectively a status print.
//
//   nexus-ce / jcr — pulls through the tool's group repo (anonymous);
//          pushes use admin/admin (the bootstrap script writes that
//          password to /tmp/cgjenkins-home/.secrets/<tool>/admin.password
//          which we read into DOCKER_CONFIG/config.json keyed on the
//          host:port the pipelines push to).
//
// Usage — call from a stage on `agent any` (the controller) BEFORE any
// stage that uses `agent { docker { image cgImage(...).build } }`:
//
//   stage('Auth') {
//     agent any
//     steps { cgLogin() }
//   }

def call() {
  // Backward compat: if .env predates MIRROR_TOOL, derive it from
  // HARBOR_ENABLED=true|false.
  def mirrorTool = env.MIRROR_TOOL ?: ((env.HARBOR_ENABLED ?: 'false') == 'true' ? 'harbor' : 'none')
  def pushAuth   = env.PUSH_AUTH ?: 'none'
  def pushRegistry = env.PUSH_REGISTRY ?: ''

  switch (mirrorTool) {
    case 'none':
      cgLoginOidc()
      return

    case 'harbor':
      if (pushRegistry.startsWith('localhost/')) {
        // Mode C: write Harbor admin creds for push.
        cgLoginBasicAuth('admin', 'Harbor12345', ['localhost', 'localhost:80'])
      } else {
        sh 'echo "cgLogin: Harbor mode, anonymous pulls + external push (no docker login needed)."'
      }
      return

    case 'distribution':
    case 'zot':
      sh "echo \"cgLogin: ${mirrorTool} mode, anonymous pulls + anonymous pushes — no docker login needed.\""
      return

    case 'nexus-ce':
      // Nexus CE doesn't support writable group repos, so pulls and
      // pushes hit two different host:ports. Write the same admin auth
      // keyed on both so docker pulls (PULL_REGISTRY host) and pushes
      // (PUSH_REGISTRY host) both work.
      def pullHost = (env.PULL_REGISTRY ?: '').split('/')[0]
      def pushHost = (env.PUSH_REGISTRY ?: '').split('/')[0]
      def hosts = [pushHost]
      if (pullHost && pullHost != pushHost) { hosts.add(pullHost) }
      cgLoginToolAdmin('nexus-ce', hosts)
      return

    case 'jcr':
      def pushHostJcr = (env.PUSH_REGISTRY ?: '').split('/')[0]
      cgLoginToolAdmin('jcr', [pushHostJcr])
      return

    default:
      error("cgLogin: unknown MIRROR_TOOL '${mirrorTool}'")
  }
}

// Mode A: per-build OIDC chainctl session.
private def cgLoginOidc() {
  def identity = readFile('/tmp/cgjenkins-home/shared-libraries/cg-images/IDENTITY').trim()
  if (!identity) {
    error('cgLogin: shared-libraries/cg-images/IDENTITY is empty — run setup.sh first (or pick a mirror tool).')
  }
  // Pass identity via the env (not Groovy ${...} interpolated into a
  // single-quoted shell string) so a UIDP containing a quote or other
  // shell metacharacter can't escape the script. sh body is a single-
  // quoted Groovy string; ${...} below is pure shell.
  withCredentials([string(credentialsId: 'jenkins-cgr-oidc', variable: 'OIDC_TOKEN')]) {
    withEnv(["CGLOGIN_IDENTITY=${identity}"]) {
      sh '''
        set -eu
        chainctl auth login --identity="$CGLOGIN_IDENTITY" --identity-token="$OIDC_TOKEN"
        chainctl auth configure-docker --identity="$CGLOGIN_IDENTITY" --identity-token="$OIDC_TOKEN"
        echo "cgLogin: authenticated as identity $CGLOGIN_IDENTITY (Mode A)."
      '''
    }
  }
}

// Write a single basic-auth credential into DOCKER_CONFIG/config.json
// keyed on every host string in `keys`. Used by Harbor (admin/Harbor12345
// keyed on bare 'localhost' for docker push and 'localhost:80' for cosign,
// whose reference parser rejects bare 'localhost').
private def cgLoginBasicAuth(String user, String pass, List<String> keys) {
  // `authsList` and the "wrote basic-auth for ..." message are Groovy-side
  // strings we control here (keys are passed by the caller and are short
  // hostnames). user/pass are also caller-controlled here, but pass via
  // env to avoid Groovy ${...} interpolating user-controlled bytes into a
  // single-quoted shell string. The sh body is a single-quoted Groovy
  // string; ${authsList} is interpolated by Groovy via a Groovy-controlled
  // string-concat below.
  def authsList = keys.collect { '"' + it + '": { "auth": "$AUTH" }' }.join(',\n    ')
  def script = '''
    set -eu
    mkdir -p "$DOCKER_CONFIG"
    AUTH=$(printf '%s:%s' "$CGLOGIN_USER" "$CGLOGIN_PASS" | base64)
    cat > "$DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {
    ''' + authsList + '''
  }
}
EOF
    echo "cgLogin: wrote basic-auth for ''' + keys.join(', ') + '''."
  '''
  withEnv(["CGLOGIN_USER=${user}", "CGLOGIN_PASS=${pass}"]) {
    sh script
  }
}

// For Nexus CE and JCR: read the admin password the bootstrap script
// persisted to /tmp/cgjenkins-home/.secrets/<tool>/admin.password, then
// write a docker config keyed on every host:port the pipeline talks to
// (some tools split pull and push across separate ports).
private def cgLoginToolAdmin(String tool, List<String> hostPorts) {
  hostPorts = hostPorts.findAll { it && it.length() > 0 }.unique()
  if (hostPorts.isEmpty()) {
    error("cgLogin: no host:port resolved for ${tool}.")
  }
  // Validate `tool` against a fixed allowlist before letting it through
  // — it composes a filesystem path below, and we'd rather fail loudly
  // than risk a poisoned value escaping the path.
  if (!(tool in ['nexus-ce', 'jcr'])) {
    error("cgLogin: cgLoginToolAdmin called with unsupported tool '${tool}'")
  }
  // authsList is Groovy-controlled (the JSON skeleton) but each host is
  // caller-controlled. JSON encode minimally — barring a `"` in a hostname
  // (which docker rejects anyway), the surrounding double quotes are
  // enough. The shell body is single-quoted Groovy, so $TOOL et al. below
  // are pure shell.
  def authsList = hostPorts.collect { '"' + it + '": { "auth": "$AUTH" }' }.join(',\n    ')
  def hostsForEcho = hostPorts.join(', ')
  def script = '''
    set -eu
    PW_FILE="/tmp/cgjenkins-home/.secrets/$CGLOGIN_TOOL/admin.password"
    if [ ! -f "$PW_FILE" ]; then
      echo "cgLogin: $CGLOGIN_TOOL admin password file not found at $PW_FILE — bootstrap may have failed." >&2
      exit 1
    fi
    PASS=$(cat "$PW_FILE")
    mkdir -p "$DOCKER_CONFIG"
    AUTH=$(printf 'admin:%s' "$PASS" | base64)
    cat > "$DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {
    ''' + authsList + '''
  }
}
EOF
    echo "cgLogin: wrote admin auth for ''' + hostsForEcho + ''' ($CGLOGIN_TOOL)."
  '''
  withEnv(["CGLOGIN_TOOL=${tool}"]) {
    sh script
  }
}
