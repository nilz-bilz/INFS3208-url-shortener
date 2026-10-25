#!/usr/bin/env bash
# Create (or reuse) the kind cluster, load images, and deploy the local overlay. Re-runnable.
# Usage: ./scripts/deploy-local.sh v1   (images must already be built with ./scripts/build.sh v1)
# The manifests reference :v1; other tags (e.g. v2) are for the rollout demo via `kubectl set image`.
set -euo pipefail

# Image tag to load into the cluster
TAG="${1:-v1}"
# Repo root, so the script works from any directory
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Run from the repo root so relative paths below resolve
cd "$ROOT"
# Container engine: podman if installed (developer machine), otherwise docker (override with CONTAINER_ENGINE=...)
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# kind needs to be told when the engine is Podman instead of Docker
if [ "$ENGINE" = podman ]; then export KIND_EXPERIMENTAL_PROVIDER=podman; fi
# Cluster name; also used in the kubectl context name (kind-shortener)
CLUSTER=shortener

# Load DB_PASSWORD and MYSQL_ROOT_PASSWORD from .env (set -a exports everything sourced)
set -a; . "$ROOT/.env"; set +a

# Create the cluster only if it does not exist yet (kind get clusters lists names; grep -x matches the whole line)
if ! kind get clusters | grep -qx "$CLUSTER"; then
  # --config sets the node layout and the 8080/8443 port mappings
  kind create cluster --name "$CLUSTER" --config kind-config.yaml
fi
# Point kubectl at the kind cluster
kubectl config use-context "kind-$CLUSTER"

# Install ingress-nginx (kind flavour: runs on the control-plane node using the host port mappings)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
# Install metrics-server (the HPA needs it to read CPU usage)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
# kind kubelets use self-signed certs, so metrics-server needs --kubelet-insecure-tls (added only once)
if ! kubectl get deploy metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  # JSON patch: append one argument to the first container's args
  kubectl patch deploy metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
# Wait until the ingress controller is Ready (--timeout caps the wait; the selector picks the controller pod)
kubectl wait -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s

# Load each image into every kind node (image-archive works with both engines; docker-image does not work with Podman)
for NAME in shortener redirect analytics frontend; do
  # Export the image to a tar archive (-o sets the output file)
  "$ENGINE" save "localhost/$NAME:$TAG" -o "/tmp/$NAME.tar"
  # Import the archive into the cluster nodes (--name selects the cluster)
  kind load image-archive "/tmp/$NAME.tar" --name "$CLUSTER"
done

# Create the namespace first so the Secret and ConfigMap below can live in it
kubectl apply -f k8s/base/namespace.yaml
# Secret from .env: --dry-run=client -o yaml renders it, apply makes the step idempotent
kubectl create secret generic app-secret -n urlshortener \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
# ConfigMap holding schema.sql, mounted into MySQL's init directory (--from-file=<key>=<path>)
kubectl create configmap mysql-init -n urlshortener --from-file=schema.sql=db/schema.sql \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply the local overlay (-k = kustomize directory)
kubectl apply -k k8s/overlays/local

# Wait for MySQL first, then every Deployment (--timeout caps each wait)
kubectl rollout status statefulset/mysql -n urlshortener --timeout=300s
for DEP in redis shortener redirect analytics-api analytics-worker frontend; do
  kubectl rollout status "deploy/$DEP" -n urlshortener --timeout=300s
done

# Show the result: pods, then the HPA (TARGETS should show a CPU %, not <unknown>, after a minute)
kubectl get pods -n urlshortener
kubectl get hpa -n urlshortener
echo "App: http://localhost:8080/ui/"
