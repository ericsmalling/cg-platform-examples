// vars/cgImage.groovy
//
// Shared-library entry point. Resolves a logical token like "corretto-java17"
// or "python-3.14" into a Map of fully-qualified Chainguard image references
// for use in `agent { docker { image '...' } }` blocks.
//
// Auto-loaded for every pipeline via JCasC (unclassified.globalLibraries with
// implicit: true). Pipelines do not need an `@Library('cgImages')` annotation.
//
// Usage:
//
//   def img = cgImage('corretto-java17')
//   pipeline {
//     stages {
//       stage('Build') {
//         agent { docker { image img.build; args '--entrypoint=' } }
//         ...
//       }
//       stage('Test') {
//         agent { docker { image img.test;  args '--entrypoint=' } }
//         ...
//       }
//     }
//   }
//
// Each token's map has some subset of these keys:
//   build    — the *-dev variant used in the Build stage
//   test     — the *-dev variant used in the Test stage (Java apps)
//   runtime  — the shell-less production target (referenced from Dockerfiles
//              that build OCI images for Python/Node apps)
//
// Image references are pinned by digest (the `@sha256:...` suffix) so that
// re-runs of a pipeline always pull the same bytes even if the upstream
// `:dev` tag is later repointed. The tag is retained alongside the digest
// for human readability — Docker accepts `repo:tag@digest` natively.
// Refresh the digests with refresh-digests.sh when you want to pick up
// newer image versions.

def call(String token) {
  // PULL_REGISTRY is set by JCasC globalNodeProperties (driven by setup.sh).
  // Defaults to cgr.dev/<org> for the no-Harbor case; switches to
  // localhost/cgr-proxy/<org> when Harbor is the active pull-through cache.
  def reg = env.PULL_REGISTRY ?: "cgr.dev/${env.CHAINGUARD_ORG}"
  def catalog = [
    'corretto-java17': [
      build: 'maven:3-jdk17-dev@sha256:2ef87b6d8b49cce6a4954346b20972ffee4f1259a4507e8f6f1b1abef180d5c0',
      test:  'amazon-corretto-jre:17-dev@sha256:a34fe97ec1f505f8db6e64651c322b4c1f135816fc993d4e2a561380be0ad1a7',
    ],
    'adoptium-java8': [
      build: 'maven:3-jdk8-dev@sha256:9e1ecf89cc12c54c3297451d5883ce4b113d58ef841eafefe4cc9d1c9af1b0a4',
      test:  'adoptium-jre:adoptium-openjdk-8-dev@sha256:e612d3dd7d0b96686e76ea2b46520675d60f8e7b0c77697ca38cfb8b1ede03db',
    ],
    'openjdk21': [
      build: 'jdk:openjdk-21-dev@sha256:916c9ee559c9df5c5e535ce8bc76abd8f77dd5908764b84dc7e21193a90588eb',
      test:  'jre:openjdk-21-dev@sha256:da97c2c594c613969b007d1822de612b8c163f52b9234ca6bb07dd89154c5fb9',
    ],
    'python-3.14': [
      build:   'python:3.14-dev@sha256:d83b1ceb93ad3c461b19ce91aa1ec5de9390d072f9b1966176d1f1678851f860',
      runtime: 'python:3.14@sha256:ab7b45ffefc935c7be5097638a1008458a6d1ea23ccc20870f35862e88c8eab6',
    ],
    'python-3.12': [
      build:   'python:3.12-dev@sha256:d016f148c8a82ccc93f57dc3ad1733c26dd8c7cde0ddac17fa9c13181377d24e',
      runtime: 'python:3.12@sha256:ba3950f1f9075ec52f0bfaaa2a45c9956fabbfb36e27cfde8eda950dc56a603f',
    ],
    'node-22': [
      build:   'node:22-dev@sha256:2cc72f0d8f860b48193c268c5b1e1d13dbb0ace7d25effcee1159d018476ca4a',
      runtime: 'node:22@sha256:fa8d7ff7a1ddd9236ca47d69809823698e0ffb8977dac80b9ab122fbfc6ad419',
    ],
    'node-25': [
      build:   'node:25-dev@sha256:40f793e15f4e8454bd6f766bb095cdf2b31f55f2509824ce0728b46fd590b96c',
      runtime: 'node:25-slim@sha256:1e196de14544a44d6cdab353e872ee7aa1ff812ff23edbe6627c954603bcd569',
    ],
  ]
  if (!catalog.containsKey(token)) {
    error("Unknown cgImage token '${token}'. Valid tokens: ${catalog.keySet().sort().join(', ')}")
  }
  return catalog[token].collectEntries { k, v -> [(k): "${reg}/${v}"] }
}
