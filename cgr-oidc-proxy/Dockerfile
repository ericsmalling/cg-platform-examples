# Builder + final base images are pulled from cgr.dev/${CHAINGUARD_ORG}/.
# Defaults to the public Chainguard catalog (`chainguard`) so anyone can
# build without an account.
#
# For reproducible builds, pin both FROM lines by digest with
# `scripts/pin-images.sh` (after setting CHAINGUARD_ORG to your org's
# name). The script rewrites this file in place. Digests are org-specific
# — pinning against one org and building against another will fail with
# "not found" because the same tag has different digests in each catalog.

ARG CHAINGUARD_ORG=chainguard

FROM cgr.dev/${CHAINGUARD_ORG}/go:latest-dev AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# Static build so the final image can be the distroless static base.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cgr-oidc-proxy .

FROM cgr.dev/${CHAINGUARD_ORG}/static:latest
COPY --from=build /out/cgr-oidc-proxy /usr/bin/cgr-oidc-proxy
USER 65532
EXPOSE 5000
ENTRYPOINT ["/usr/bin/cgr-oidc-proxy"]
