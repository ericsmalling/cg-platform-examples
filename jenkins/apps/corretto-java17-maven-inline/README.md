# corretto-java17-maven-inline

Teaching twin of [`../corretto-java17-maven`](../corretto-java17-maven). The
application code and pom.xml are byte-for-byte identical. The only
difference is the Jenkinsfile: every call into the `cg-images` shared
library (`cgImage`, `cgLogin`) is expanded to the literal shell + docker
commands it produces.

This pipeline only builds and tests a jar — there's no image push, so
there's no `cgSign` / `cgVerify` to inline. For an example that includes
those, see
[`../python314-uv-flask-inline`](../python314-uv-flask-inline).

## Caveats

- **Hardcoded for one configuration.** The Jenkinsfile assumes setup.sh ran
  with `MIRROR_TOOL=harbor`, `AUTH_MODE=proxy`, push-to-library, and
  `CHAINGUARD_ORG=smalls.xyz`. Other modes need different image references.
  The shared-library version handles all six modes from a single
  Jenkinsfile.
- **Digest pins drift.** `BUILD_IMAGE` / `TEST_IMAGE` are pinned by digest,
  matching the current entry in
  [`shared-libraries/cg-images/vars/cgImage.groovy`](../../shared-libraries/cg-images/vars/cgImage.groovy).
  When the scheduled `refresh-cgimages-digests` job updates that catalog,
  this Jenkinsfile keeps the old digests — that's by design (it's a
  snapshot, not a live binding) but means manual maintenance to track.

If you're starting a new pipeline, use the shared-library form. This twin
exists for the moment when you want to see what those calls compile down
to.
