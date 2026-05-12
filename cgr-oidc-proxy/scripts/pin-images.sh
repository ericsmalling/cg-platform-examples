#!/usr/bin/env bash
# Pin (or refresh) the base-image digests on the Dockerfile's FROM lines.
#
# Digests on cgr.dev are *catalog-specific* — `cgr.dev/chainguard/static:latest`
# and `cgr.dev/your-org.example.com/static:latest` have different digests
# even when they "are" the same image. So pinning is something each
# operator does against their own org's catalog. The default Dockerfile
# is shipped unpinned so it works for any org; run this script when you
# want reproducible builds.
#
# Usage:
#   CHAINGUARD_ORG=chainguard ./scripts/pin-images.sh
#   CHAINGUARD_ORG=your-org.example.com ./scripts/pin-images.sh
#
# The script rewrites the sibling Dockerfile in place. Commit the result.
# Re-run periodically (or in CI nightly) to refresh.
#
# Requires:
#   crane (recommended: cgr.dev/chainguard/crane) OR docker buildx
#   chainctl auth login + chainctl auth configure-docker against the org

set -euo pipefail

cd "$(dirname "$0")/.."

: "${CHAINGUARD_ORG:?CHAINGUARD_ORG must be set (e.g. 'chainguard' or 'your-org.example.com')}"

if command -v crane >/dev/null 2>&1; then
  digest() { crane digest "$1"; }
else
  echo "==> crane not on PATH; falling back to 'docker buildx imagetools'."
  digest() { docker buildx imagetools inspect "$1" --format '{{ json .Manifest.Digest }}' | tr -d '"'; }
fi

GO_TAG="cgr.dev/${CHAINGUARD_ORG}/go:latest-dev"
STATIC_TAG="cgr.dev/${CHAINGUARD_ORG}/static:latest"

echo "==> Resolving digests against cgr.dev/${CHAINGUARD_ORG}/ ..."
GO_DIGEST="$(digest "$GO_TAG")"
STATIC_DIGEST="$(digest "$STATIC_TAG")"
TODAY="$(date -u '+%Y-%m-%d')"

echo "    $GO_TAG → $GO_DIGEST"
echo "    $STATIC_TAG → $STATIC_DIGEST"

# Replace the two FROM lines plus the comment header so future readers can
# tell whether the file is currently pinned (and against which org).
python3 - "$CHAINGUARD_ORG" "$GO_DIGEST" "$STATIC_DIGEST" "$TODAY" <<'PY'
import sys, re
org, go_digest, static_digest, today = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = "Dockerfile"
s = open(p).read()

# Top-of-file comment: replace the "default" preface with a pinned-state preface.
pinned_header = f"""# Builder + final base images are pinned by digest against
# cgr.dev/{org}/ (resolved {today}). Re-run scripts/pin-images.sh to refresh.
# Digests are catalog-specific — to switch CHAINGUARD_ORG you must also
# re-pin (or unpin) the digests on the FROM lines below."""

# Match either the unpinned preface or a prior pinned preface.
unpinned_preface = re.compile(
    r"# Builder \+ final base images are pulled from cgr\.dev/\$\{CHAINGUARD_ORG\}/\.\n"
    r"# Defaults to the public Chainguard catalog \(`chainguard`\) so anyone can\n"
    r"# build without an account\.\n"
    r"#\n"
    r"# For reproducible builds, pin both FROM lines by digest with\n"
    r"# `scripts/pin-images\.sh` \(after setting CHAINGUARD_ORG to your org's\n"
    r"# name\)\. The script rewrites this file in place\. Digests are org-specific\n"
    r"# — pinning against one org and building against another will fail with\n"
    r"# \"not found\" because the same tag has different digests in each catalog\."
)
pinned_preface = re.compile(
    r"# Builder \+ final base images are pinned by digest against\n"
    r"# cgr\.dev/[^/\s]+/ \(resolved \d{4}-\d{2}-\d{2}\)\. Re-run scripts/pin-images\.sh to refresh\.\n"
    r"# Digests are catalog-specific — to switch CHAINGUARD_ORG you must also\n"
    r"# re-pin \(or unpin\) the digests on the FROM lines below\."
)
if unpinned_preface.search(s):
    s = unpinned_preface.sub(pinned_header, s)
elif pinned_preface.search(s):
    s = pinned_preface.sub(pinned_header, s)

# FROM lines: regardless of current pinned/unpinned state, normalize to pinned.
s = re.sub(
    r"FROM cgr\.dev/\$\{CHAINGUARD_ORG\}/go:latest-dev(@sha256:[a-f0-9]{64})? AS build",
    f"FROM cgr.dev/${{CHAINGUARD_ORG}}/go:latest-dev@{go_digest} AS build",
    s,
)
s = re.sub(
    r"FROM cgr\.dev/\$\{CHAINGUARD_ORG\}/static:latest(@sha256:[a-f0-9]{64})?",
    f"FROM cgr.dev/${{CHAINGUARD_ORG}}/static:latest@{static_digest}",
    s,
)
open(p, "w").write(s)
PY

echo "==> Dockerfile pinned against cgr.dev/${CHAINGUARD_ORG}/ (resolved ${TODAY})."
echo "    Commit the change. Switching CHAINGUARD_ORG later? Re-run this script."
