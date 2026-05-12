# syntax=docker/dockerfile:1
# Stage 1: install Django into the system site-packages with pip. The default
# uid (65532) on python:3.12-dev can't write there, so switch to root for the
# install. Stage 2 then copies the populated site-packages into the shell-less
# python:3.12 runtime image — same Python minor version on both sides keeps
# the packages compatible.
#
# PULL_REGISTRY routes base-image pulls through whichever mirror tool setup.sh
# picked (Harbor's cgr-proxy project, distribution, zot, etc.). The Jenkins
# controller's docker daemon doesn't see the in-cluster cgr-oidc-proxy, so
# hardcoding cgr.dev here would 401 in mirror modes (proxy + pull-token).
# In none mode, PULL_REGISTRY is cgr.dev/$ORG and cgLogin sets up the
# docker-credential-cgr helper for it.
ARG PULL_REGISTRY

FROM ${PULL_REGISTRY}/python:3.12-dev AS build
USER 0
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

FROM ${PULL_REGISTRY}/python:3.12
COPY --from=build /usr/lib/python3.12/site-packages /usr/lib/python3.12/site-packages
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
