#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# URL shortener: deploy to a local kind cluster (INFS3208, Type I project)
#
# Author:         Nihal Singh Atwal
# Student ID:     49299175
# Email:          nihalsingh.atwal@student.uq.edu.au
# AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
#
# What it does: creates (or reuses) a 3-node kind cluster, installs ingress-nginx and
# metrics-server, loads the locally built images into the nodes, creates the Secret and the
# MySQL init ConfigMap, applies the local overlay and waits for every rollout. Safe to re-run.
# Every command is printed (prefixed with "$") with a one-line description before it runs.
#
# Prerequisites
#   - Tools: kind, kubectl, and podman or docker. Internet access (downloads the ingress-nginx
#     and metrics-server manifests and their images).
#   - Images are built with the same tag:  ./scripts/build.sh <tag>
#   - .env exists in the repo root (cp .env.example .env).
#   - Host inotify limits are raised or kind nodes fail to start ("too many open files"):
#       sudo sysctl fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288
#   - Port 8080 on the host is free (kind-config.yaml maps host 8080 -> ingress 80).
#   - Rootless Podman: the script sets KIND_EXPERIMENTAL_PROVIDER=podman automatically.
#
# Usage:  ./scripts/deploy-local.sh [tag]
#   tag          image tag to load (default v1). The manifests reference :v1; other tags
#                (for example v2) are meant for the rollout demo via `kubectl set image`.
# Environment:
#   CONTAINER_ENGINE   podman or docker (default: podman if installed, else docker)
#   DRY_RUN=1          print the commands without running them
# ------------------------------------------------------------------------------
set -euo pipefail

TAG="${1:-v1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CLUSTER=shortener   # also the kubectl context suffix (kind-shortener)
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# kind needs to be told when the engine is Podman instead of Docker
if [ "$ENGINE" = podman ]; then export KIND_EXPERIMENTAL_PROVIDER=podman; fi

# Load DB_PASSWORD and MYSQL_ROOT_PASSWORD (set -a exports everything sourced)
set -a; . "$ROOT/.env"; set +a

# ---- helpers ----------------------------------------------------------------

# Print "# description" and "$ command", then run the command (unless DRY_RUN=1)
run() {
  printf '\n# %s\n$ %s\n' "$1" "$2"
  if [ -z "${DRY_RUN:-}" ]; then eval "$2"; fi
}

# Print a section heading
section() { printf '\n==== %s ====\n' "$1"; }

# ---- steps ------------------------------------------------------------------

create_cluster() {
  section "kind cluster ($ENGINE)"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "Cluster '$CLUSTER' already exists; reusing it."
  else
    run "Create the cluster (--config sets 1 control-plane + 2 workers and the 8080/8443 port mappings)" \
        "kind create cluster --name $CLUSTER --config kind-config.yaml"
  fi
  run "Point kubectl at the kind cluster" "kubectl config use-context kind-$CLUSTER"
}

install_addons() {
  section "ingress-nginx and metrics-server"
  run "Install ingress-nginx (kind flavour: runs on the control-plane node using the host port mappings)" \
      "kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml"
  run "Install metrics-server (the HPA needs it to read CPU usage)" \
      "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml"
  # kind kubelets use self-signed certificates, so metrics-server needs --kubelet-insecure-tls (added once)
  if kubectl get deploy metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q kubelet-insecure-tls; then
    echo "metrics-server already has --kubelet-insecure-tls."
  else
    run "Add --kubelet-insecure-tls to metrics-server (JSON patch appends one container argument)" \
        "kubectl patch deploy metrics-server -n kube-system --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'"
  fi
  run "Wait until the ingress controller is Ready (--timeout caps the wait)" \
      "kubectl wait -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s"
}

load_images() {
  section "Load images into the kind nodes"
  local name
  for name in shortener redirect analytics frontend; do
    run "Export $name:$TAG to a tar archive (-o sets the output file)" \
        "$ENGINE save localhost/$name:$TAG -o /tmp/$name.tar"
    run "Import the archive into every node (image-archive works with both engines; docker-image does not work with Podman)" \
        "kind load image-archive /tmp/$name.tar --name $CLUSTER"
  done
}

apply_config() {
  section "Namespace, Secret and ConfigMap"
  run "Create the namespace first so the Secret and ConfigMap can live in it" \
      "kubectl apply -f k8s/base/namespace.yaml"
  # The password is expanded when the command runs but never printed (escaped \$)
  run "Create the Secret from .env (--dry-run=client renders it, apply keeps the step idempotent)" \
      "kubectl create secret generic app-secret -n urlshortener --from-literal=DB_PASSWORD=\"\$DB_PASSWORD\" --from-literal=MYSQL_ROOT_PASSWORD=\"\$MYSQL_ROOT_PASSWORD\" --dry-run=client -o yaml | kubectl apply -f -"
  run "Create the ConfigMap holding schema.sql, mounted into MySQL's init directory (--from-file=<key>=<path>)" \
      "kubectl create configmap mysql-init -n urlshortener --from-file=schema.sql=db/schema.sql --dry-run=client -o yaml | kubectl apply -f -"
}

apply_overlay() {
  section "Apply the local overlay"
  run "Apply the overlay (-k = kustomize directory: base manifests + local Ingress + BASE_URL patch)" \
      "kubectl apply -k k8s/overlays/local"
}

wait_for_rollouts() {
  section "Wait for everything to be Ready"
  local dep
  run "Wait for MySQL (--timeout caps the wait)" \
      "kubectl rollout status statefulset/mysql -n urlshortener --timeout=300s"
  for dep in redis shortener redirect analytics-api analytics-worker frontend; do
    run "Wait for the $dep Deployment" \
        "kubectl rollout status deploy/$dep -n urlshortener --timeout=300s"
  done
}

summary() {
  section "Result"
  run "List the pods (all should be Running and Ready)" "kubectl get pods -n urlshortener"
  run "Show the autoscaler (TARGETS needs about a minute before it shows a CPU %, not <unknown>)" \
      "kubectl get hpa -n urlshortener"
  echo; echo "App: http://localhost:8080/ui/"
}

# ---- main -------------------------------------------------------------------

main() {
  create_cluster
  install_addons
  load_images
  apply_config
  apply_overlay
  wait_for_rollouts
  summary
}

main
