# CLAUDE.md

URL shortener for INFS3208 (Type I project): a minimal app deployed as microservices on Kubernetes (kind locally, GKE in the cloud). Due 27 Oct 2026, 3 PM.

**The spec is the source of truth: `docs/SPEC.md`.** Read it before starting any task. Follow its step-by-step plan (section 9) in order, and do not start a step until the previous step's "Done when" check passes. If this file and the spec disagree, the spec wins.

## Goal and priorities

The app is deliberately tiny. Marks come from the Kubernetes features: microservices, scaling, reliability, load balancing, orchestration, rollout/rollback. When in doubt, spend effort there, not on app features or UI.

## KISS rules (strict)

- Build only what the spec lists. No extra features, endpoints, tables, services or dependencies.
- Do not add: ORMs, JS or CSS frameworks, build steps for the frontend, Helm, CI/CD, message brokers other than Redis, service mesh, unit-test frameworks.
- Python 3.12 + Flask + gunicorn + PyMySQL + redis-py only. Plain SQL with parameterised queries (`%s`), never string formatting.
- Keep each service under ~200 lines. Duplicating the small `common.py` helper in each service is intended; do not create a shared package.
- All config comes from environment variables (spec section 4). Nothing environment-specific inside images.
- Frontend is brutalist: plain HTML, vanilla JS, monospace, black on white, borders, no rounded corners.
- If something is not covered by the spec, choose the simplest option and record it under "Decisions" in `README.md`. Ask before making any choice that changes the architecture.

## Conventions

- Every backend listens on port 8000; frontend nginx on 80. Kubernetes Services expose port 80.
- Every service has `GET /healthz` (no dependency checks) and `GET /readyz` (checks MySQL and Redis).
- Every backend response includes `X-Served-By` (pod hostname) and `X-App-Version` (from `APP_VERSION`, baked into the image at build time).
- JSON errors are always `{"error": "<message>"}`.
- Image names: `localhost/<service>:<tag>` locally; the GKE overlay rewrites them to Artifact Registry.
- Never commit secrets. `.env` is git-ignored; `.env.example` holds dev defaults.

## Commands must be commented

Every command in `README.md` and `scripts/*.sh` must have a comment explaining what it does and its key parameters. This is marked. Example:

```bash
# Roll back the redirect Deployment to its previous revision (-n selects the namespace)
kubectl rollout undo deploy/redirect -n urlshortener
```

Scripts start with `set -euo pipefail` and should be safe to re-run.

## Environment (developer machine)

- Fedora Silverblue with **Podman**, not Docker. Use `podman` and `podman-compose`.
- kind runs on the host with `KIND_EXPERIMENTAL_PROVIDER=podman`. Rootless: the kind config maps ports 80 → 8080 and 443 → 8443.
- Load images into kind with `podman save ... -o /tmp/x.tar` then `kind load image-archive /tmp/x.tar --name shortener`. `kind load docker-image` does not work with Podman.
- `hey` may run inside a toolbox container.

## Common commands

```bash
# Stage 1: run everything with Compose; the app is at http://localhost:8080/ui/
podman-compose up -d --build

# Build all four images with tag v1 as localhost/<name>:v1
./scripts/build.sh v1

# Stage 2: create/refresh the kind cluster, load images, apply the local overlay
./scripts/deploy-local.sh v1

# Render manifests without applying them (quick validation)
kubectl kustomize k8s/overlays/local

# Watch all pods in the app namespace
kubectl get pods -n urlshortener -w

# Stage 3: push images and deploy to GKE
./scripts/deploy-gke.sh v1
```

## How to verify work

- Use the "Done when" check from the spec for the current step; run it with `curl` and paste the result into your summary.
- Before declaring Kubernetes work done: all pods Ready, `kubectl get hpa -n urlshortener` shows a CPU %, and a `curl` loop against a short link shows no non-302 responses while you delete a redirect pod.
- Do not mark a step complete if a check fails; say what failed.

## Safety

- Never run destructive commands against GKE (deleting the cluster, namespace, PVCs or the static IP) without asking first.
- Ask before any `gcloud` command that creates billable resources.
- Do not change `k8s/base` resource requests, replica counts or HPA bounds without a reason tied to the spec.

## Layout (see spec section 4 for detail)

```
frontend/  shortener/  redirect/  analytics/   # one folder per image
db/schema.sql                                  # MySQL schema
gateway/nginx.conf                             # Compose-only router mimicking the Ingress
k8s/base  k8s/overlays/{local,gke}             # Kustomize manifests
scripts/                                       # build, deploy, seed, demo
docs/SPEC.md  docs/architecture.drawio         # spec and architecture figure
```
