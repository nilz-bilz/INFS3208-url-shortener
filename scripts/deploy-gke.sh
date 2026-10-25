#!/usr/bin/env bash
# Push images to Artifact Registry and deploy the gke overlay. Re-runnable.
# Usage: [DOMAIN=s.example.com | PUBLIC_URL=https://s.example.com] ./scripts/deploy-gke.sh v1
# DOMAIN: Google managed certificate (DNS must point straight at the static IP).
# PUBLIC_URL: HTTPS terminated elsewhere (e.g. Cloudflare proxy); no certificate is created here.
# Prereqs (one-off, see README): GKE cluster, Artifact Registry repo "urlshortener", global static IP "shortener-ip".
set -euo pipefail

# Image tag to push and deploy
TAG="${1:-v1}"
# Repo root, so the script works from any directory
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Run from the repo root so relative paths below resolve
cd "$ROOT"
# Container engine: podman if installed, otherwise docker (override with CONTAINER_ENGINE=...)
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# Project, region and zone default to the active gcloud config (override with PROJECT_ID, REGION, ZONE)
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null)}"
ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
# Cluster name and Artifact Registry path
CLUSTER="${CLUSTER:-shortener}"
REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/urlshortener"
# kubectl always targets the GKE context explicitly, so the kind context is never touched
KCTX="gke_${PROJECT_ID}_${ZONE}_${CLUSTER}"
KUBECTL="kubectl --context $KCTX"

# Load DB_PASSWORD and MYSQL_ROOT_PASSWORD from .env (set -a exports everything sourced)
set -a; . "$ROOT/.env"; set +a

# Write a kubeconfig entry for the cluster (--zone selects the zonal cluster)
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE"
# Let the container engine push to Artifact Registry (adds a credential helper for that host; --quiet skips prompts)
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

# Look up the reserved global static IP; fail early with a clear message if it does not exist
IP="$(gcloud compute addresses describe shortener-ip --global --format='value(address)')"
# Public address used in short links: the domain if given (https), otherwise the static IP (http)
if [ -n "${PUBLIC_URL:-}" ]; then BASE_URL="${PUBLIC_URL%/}"; elif [ -n "${DOMAIN:-}" ]; then BASE_URL="https://$DOMAIN"; else BASE_URL="http://$IP"; fi
echo "Deploying $TAG to $KCTX, public address $BASE_URL"

for NAME in shortener redirect analytics frontend; do
  # Tag the local image with its registry name
  "$ENGINE" tag "localhost/$NAME:$TAG" "$REGISTRY/$NAME:$TAG"
  # Push it to Artifact Registry
  "$ENGINE" push "$REGISTRY/$NAME:$TAG"
done

# Create the namespace first so the Secret and ConfigMap below can live in it
$KUBECTL apply -f k8s/base/namespace.yaml
# Secret from .env: --dry-run=client -o yaml renders it, apply makes the step idempotent
$KUBECTL create secret generic app-secret -n urlshortener \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
# ConfigMap holding schema.sql, mounted into MySQL's init directory (--from-file=<key>=<path>)
$KUBECTL create configmap mysql-init -n urlshortener --from-file=schema.sql=db/schema.sql \
  --dry-run=client -o yaml | $KUBECTL apply -f -

# Render the overlay, fill in the placeholders, and apply (kubectl kustomize renders without applying)
$KUBECTL kustomize k8s/overlays/gke \
  | sed -e "s#__PROJECT_ID__#$PROJECT_ID#g" -e "s#__TAG__#$TAG#g" -e "s#__BASE_URL__#$BASE_URL#g" \
  | $KUBECTL apply -f -

# Optional HTTPS: create the managed certificate and attach it to the Ingress
if [ -n "${DOMAIN:-}" ]; then
  sed "s#__DOMAIN__#$DOMAIN#" k8s/overlays/gke/managed-cert.yaml | $KUBECTL apply -f -
  # --overwrite makes re-runs safe
  $KUBECTL annotate ingress shortener-ingress -n urlshortener networking.gke.io/managed-certificates=shortener-cert --overwrite
fi

# Wait for MySQL first, then every Deployment (--timeout caps each wait)
$KUBECTL rollout status statefulset/mysql -n urlshortener --timeout=600s
for DEP in redis shortener redirect analytics-api analytics-worker frontend; do
  $KUBECTL rollout status "deploy/$DEP" -n urlshortener --timeout=600s
done

# Show the result: pods, HPA and Ingress (the Ingress can take several minutes to get healthy backends)
$KUBECTL get pods -n urlshortener
$KUBECTL get hpa -n urlshortener
$KUBECTL get ingress -n urlshortener
echo "App: $BASE_URL/ui/"
