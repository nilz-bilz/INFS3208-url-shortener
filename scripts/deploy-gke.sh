#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# URL shortener: deploy to GKE (INFS3208, Type I project)
#
# Author:         Nihal Singh Atwal 
# Student ID:     49299175
# Email:          nihalsingh.atwal@student.uq.edu.au
# AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
#
# What it does: pushes the four images to Artifact Registry, creates the Secret and
# the MySQL init ConfigMap, applies the gke overlay (Deployments, StatefulSet, Services,
# HPA, Ingress) and waits for every rollout. Safe to re-run.
# Every command is printed (prefixed with "$") with a one-line description before it runs.
#
# Prerequisites (one-off, see README "GKE")
#   - Tools: gcloud (with gke-gcloud-auth-plugin), kubectl, podman or docker, sed.
#   - gcloud is logged in and its config has project, compute/region and compute/zone set.
#   - A GKE cluster exists (default name "shortener"), plus an Artifact Registry repo
#     "urlshortener" in the same region and a reserved global static IP "shortener-ip".
#   - Images are built locally with the same tag:  ./scripts/build.sh <tag>
#   - .env exists in the repo root (DB_PASSWORD, MYSQL_ROOT_PASSWORD; use strong values for GKE).
#
# Usage:  [DOMAIN=s.example.com | PUBLIC_URL=https://s.example.com] ./scripts/deploy-gke.sh [tag]
#   tag          image tag to push and deploy (default v1)
# Environment:
#   DOMAIN       create a Google managed certificate for this host (DNS must point straight at the static IP)
#   PUBLIC_URL   public https URL when HTTPS is terminated elsewhere (e.g. Cloudflare proxy); no certificate is created
#   PROJECT_ID, REGION, ZONE, CLUSTER   override the gcloud config / default cluster name
#   CONTAINER_ENGINE                    podman or docker (default: podman if installed, else docker)
#   DRY_RUN=1    print the commands without running them (variables are still looked up with gcloud)
# ------------------------------------------------------------------------------
set -euo pipefail

TAG="${1:-v1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---- helpers ----------------------------------------------------------------

# Print "# description" and "$ command", then run the command (unless DRY_RUN=1)
run() {
  printf '\n# %s\n$ %s\n' "$1" "$2"
  if [ -z "${DRY_RUN:-}" ]; then eval "$2"; fi
}

# Print a section heading
section() { printf '\n==== %s ====\n' "$1"; }

# ---- configuration ----------------------------------------------------------

# Resolve names, the registry path and the public URL; fail early if the static IP is missing
configure() {
  ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
  REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null)}"
  ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null)}"
  CLUSTER="${CLUSTER:-shortener}"
  REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/urlshortener"
  # kubectl always targets the GKE context explicitly, so a kind context is never touched
  K="kubectl --context gke_${PROJECT_ID}_${ZONE}_${CLUSTER}"

  # Load DB_PASSWORD and MYSQL_ROOT_PASSWORD (set -a exports everything sourced)
  set -a; . "$ROOT/.env"; set +a

  IP="$(gcloud compute addresses describe shortener-ip --global --format='value(address)')"
  if [ -n "${PUBLIC_URL:-}" ]; then BASE_URL="${PUBLIC_URL%/}"
  elif [ -n "${DOMAIN:-}" ]; then BASE_URL="https://$DOMAIN"
  else BASE_URL="http://$IP"; fi

  echo "Project:  $PROJECT_ID   Cluster: $CLUSTER ($ZONE)   Engine: $ENGINE"
  echo "Registry: $REGISTRY"
  echo "Deploying tag $TAG, public address $BASE_URL"
}

# ---- steps ------------------------------------------------------------------

connect() {
  section "Connect to the cluster and the registry"
  run "Write a kubeconfig entry for the cluster (--zone selects the zonal cluster)" \
      "gcloud container clusters get-credentials $CLUSTER --zone $ZONE"
  run "Let $ENGINE push to Artifact Registry (adds a credential helper; --quiet skips prompts)" \
      "gcloud auth configure-docker $REGION-docker.pkg.dev --quiet"
}

push_images() {
  section "Push images"
  local name
  for name in shortener redirect analytics frontend; do
    run "Tag the local $name image with its registry name" \
        "$ENGINE tag localhost/$name:$TAG $REGISTRY/$name:$TAG"
    run "Push $name:$TAG to Artifact Registry" \
        "$ENGINE push $REGISTRY/$name:$TAG"
  done
}

apply_config() {
  section "Namespace, Secret and ConfigMap"
  run "Create the namespace first so the Secret and ConfigMap can live in it" \
      "$K apply -f k8s/base/namespace.yaml"
  # Single quotes: the password is expanded when the command runs but is never printed
  run "Create the Secret from .env (--dry-run=client renders it, apply keeps the step idempotent)" \
      "$K create secret generic app-secret -n urlshortener --from-literal=DB_PASSWORD=\"\$DB_PASSWORD\" --from-literal=MYSQL_ROOT_PASSWORD=\"\$MYSQL_ROOT_PASSWORD\" --dry-run=client -o yaml | $K apply -f -"
  run "Create the ConfigMap holding schema.sql, mounted into MySQL's init directory (--from-file=<key>=<path>)" \
      "$K create configmap mysql-init -n urlshortener --from-file=schema.sql=db/schema.sql --dry-run=client -o yaml | $K apply -f -"
}

apply_overlay() {
  section "Apply the gke overlay"
  run "Render the overlay, fill in project, tag and public URL, and apply it (kustomize renders without applying)" \
      "$K kustomize k8s/overlays/gke | sed -e 's#__PROJECT_ID__#$PROJECT_ID#g' -e 's#__TAG__#$TAG#g' -e 's#__BASE_URL__#$BASE_URL#g' | $K apply -f -"
}

enable_https() {
  [ -n "${DOMAIN:-}" ] || return 0
  section "Google managed certificate for $DOMAIN"
  run "Create the ManagedCertificate for the domain" \
      "sed 's#__DOMAIN__#$DOMAIN#' k8s/overlays/gke/managed-cert.yaml | $K apply -f -"
  run "Attach it to the Ingress (--overwrite makes re-runs safe)" \
      "$K annotate ingress shortener-ingress -n urlshortener networking.gke.io/managed-certificates=shortener-cert --overwrite"
}

wait_for_rollouts() {
  section "Wait for everything to be Ready"
  local dep
  run "Wait for MySQL (--timeout caps the wait)" \
      "$K rollout status statefulset/mysql -n urlshortener --timeout=600s"
  for dep in redis shortener redirect analytics-api analytics-worker frontend; do
    run "Wait for the $dep Deployment" \
        "$K rollout status deploy/$dep -n urlshortener --timeout=600s"
  done
}

summary() {
  section "Result"
  run "List the pods (all should be Running and Ready)" "$K get pods -n urlshortener"
  run "Show the autoscaler (TARGETS needs a minute before it shows a CPU %)" "$K get hpa -n urlshortener"
  run "Show the Ingress (the load balancer can take several minutes to get healthy backends)" "$K get ingress -n urlshortener"
  echo; echo "App: $BASE_URL/ui/"
}

# ---- main -------------------------------------------------------------------

main() {
  configure
  connect
  push_images
  apply_config
  apply_overlay
  enable_https
  wait_for_rollouts
  summary
}

main
