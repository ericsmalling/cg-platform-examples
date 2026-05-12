# python314-uv-flask-inline

This is a teaching twin of [`../python314-uv-flask`](../python314-uv-flask).
The application code, Dockerfile, and pyproject.toml are byte-for-byte
identical. The only difference is the Jenkinsfile: every call into the
`cg-images` shared library (`cgImage`, `cgLogin`, `cgSign`, `cgVerify`) is
expanded to the literal shell + docker commands it produces.

It's meant to make the auth flow, image-ref construction, and digest
resolution visible to someone reading the pipeline alongside its
shared-library siblings. The plumbing is the same — it's just lifted out
of helper functions and into the Jenkinsfile body.

## Caveats

- **Hardcoded for one configuration.** The Jenkinsfile assumes setup.sh ran
  with `MIRROR_TOOL=harbor`, `AUTH_MODE=proxy`, push-to-library, and
  `CHAINGUARD_ORG=smalls.xyz`. Other modes need different image references
  and a different `Auth` stage. The shared-library version handles all six
  modes from a single Jenkinsfile.
- **Digest pins drift.** `BUILD_IMAGE` / `RUNTIME_IMAGE` are pinned by
  digest, matching the current entry in
  [`shared-libraries/cg-images/vars/cgImage.groovy`](../../shared-libraries/cg-images/vars/cgImage.groovy).
  When the scheduled `refresh-cgimages-digests` job updates that catalog,
  this Jenkinsfile keeps the old digests — that's by design (it's a
  snapshot, not a live binding) but means manual maintenance to track.

If you're starting a new pipeline, use the shared-library form. This twin
exists for the moment when you want to see what those calls compile down
to.
