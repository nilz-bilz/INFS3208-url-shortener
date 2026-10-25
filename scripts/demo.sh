#!/usr/bin/env bash
# Demo commands in spec order (section 10), with a pause between steps.
# Usage: ./scripts/demo.sh [CODE]   (CODE = a short code; defaults to the first link of the seeded demo user)
# Env: HOST (default http://localhost:8080), REDIRECT_V2 (v2 image for the rollout step), NOPAUSE=1 (no prompts)
set -euo pipefail

# Where the app is reachable (kind: localhost:8080; GKE: https://s.yourdomain.com)
HOST="${HOST:-http://localhost:8080}"
# Namespace used by every kubectl command below
NS=urlshortener
# Image the rollout step switches to (on GKE use the Artifact Registry path)
REDIRECT_V2="${REDIRECT_V2:-localhost/redirect:v2}"
# File where background curl loops write one HTTP status code per line
LOOP_OUT="$(mktemp)"
# Stop any background loop and remove the temp file when the script exits
trap 'kill $(jobs -p) 2>/dev/null || true; rm -f "$LOOP_OUT"' EXIT

# Use the given short code, or log in as the seeded demo user and take its first link
if [ -n "${1:-}" ]; then
  CODE="$1"
else
  # Log in (-s silent, -d sends the JSON body) and extract the token with python3
  TOKEN=$(curl -s -d '{"username":"demo","password":"demo1234"}' -H 'Content-Type: application/json' "$HOST/api/auth/login" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
  # List the demo user's links and take the first one that never expires (seeded links 45-49 are already expired)
  CODE=$(curl -s -H "Authorization: Bearer $TOKEN" "$HOST/api/links" \
    | python3 -c 'import sys,json; print(next(l for l in json.load(sys.stdin) if not l["expires_at"])["code"])')
fi
echo "Using $HOST/$CODE"

# Wait for Enter between steps (skipped when NOPAUSE=1)
pause() { if [ -z "${NOPAUSE:-}" ]; then read -rp "--- press Enter for the next step ---"; fi; }
# Start a background loop that requests the short link every 0.2s and records the status codes (-m 3: a hung request counts as 000)
start_loop() { ( while true; do curl -s -m 3 -o /dev/null -w "%{http_code}\n" "$HOST/$CODE" >> "$LOOP_OUT"; sleep 0.2; done ) & LOOP_PID=$!; }
# Stop the background loop and summarise the status codes it saw (sort | uniq -c counts each code)
stop_loop() { kill "$LOOP_PID" 2>/dev/null || true; wait "$LOOP_PID" 2>/dev/null || true; sort "$LOOP_OUT" | uniq -c; : > "$LOOP_OUT"; }

echo "== 1. App tour: open $HOST/ui/ in the browser, log in as demo/demo1234, create a link, open it, show stats and top links"
pause

echo "== 2. Load balancing: X-Served-By should show different pods"
for i in $(seq 6); do
  # -s silent, -I headers only, grep keeps the pod name header
  curl -sI "$HOST/$CODE" | grep -i x-served-by
done
pause

echo "== 3. Manual scaling: shortener 2 -> 4 replicas"
# Scale the shortener Deployment to 4 replicas
kubectl scale deploy/shortener --replicas=4 -n "$NS"
# Wait until all 4 are available (--timeout caps the wait)
kubectl rollout status deploy/shortener -n "$NS" --timeout=120s
# List the shortener pods (-l filters by label)
kubectl get pods -n "$NS" -l app=shortener
# Put it back to 2 so the demo can be re-run
kubectl scale deploy/shortener --replicas=2 -n "$NS"
pause

echo "== 4. Autoscaling: 45 s of load on the redirect service, watch the HPA"
# Generate load in the background: hey if installed (-z duration, -c concurrency, -disable-redirects stops it following the 302)
if command -v hey >/dev/null 2>&1; then
  hey -z 45s -c 50 -disable-redirects "$HOST/$CODE" >/dev/null &
else
  # Fallback: 60 parallel curls for 45 s (timeout stops the loop)
  timeout 45 bash -c "while true; do seq 200 | xargs -P 60 -I{} curl -s -o /dev/null $HOST/$CODE; done" &
fi
# Print the HPA every 10 s while the load runs (TARGETS = CPU %, REPLICAS should rise above 3)
for i in 1 2 3 4 5; do sleep 10; kubectl get hpa redirect -n "$NS" --no-headers; done
# Wait for the load generator to finish
wait
pause

echo "== 5. Reliability: delete every redirect pod while requests keep flowing (expect only 302)"
start_loop
sleep 5
# Delete all redirect pods at once (--wait=false returns immediately); the Deployment recreates them
kubectl delete pod -l app=redirect -n "$NS" --wait=false
# Give the replacements time to become Ready
sleep 25
stop_loop
# Optional: drain a node that does not run mysql-0 (find it with: kubectl get pods -n $NS -o wide), then uncordon it
#   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
#   kubectl uncordon <node>
pause

echo "== 6. Rollout: redirect -> v2 with traffic flowing (expect only 302)"
start_loop
sleep 3
# Switch the redirect container to the v2 image; the RollingUpdate keeps all pods serving (maxUnavailable: 0)
kubectl set image deploy/redirect redirect="$REDIRECT_V2" -n "$NS"
# Record why the revision exists so rollout history is readable
kubectl annotate deploy/redirect kubernetes.io/change-cause="v2" -n "$NS" --overwrite
# Wait for the rollout to finish
kubectl rollout status deploy/redirect -n "$NS" --timeout=420s
stop_loop
# The version header should now say v2
curl -sI "$HOST/$CODE" | grep -i x-app-version
pause

echo "== 7. Rollback: back to the previous revision"
# Show the revisions
kubectl rollout history deploy/redirect -n "$NS"
# Roll back to the previous revision
kubectl rollout undo deploy/redirect -n "$NS"
# Wait for the rollback to finish
kubectl rollout status deploy/redirect -n "$NS" --timeout=420s
# Relabel the revision (undo copies the old change-cause, which would still say v2)
kubectl annotate deploy/redirect kubernetes.io/change-cause="rollback to v1" -n "$NS" --overwrite
# The version header should be back to v1
curl -sI "$HOST/$CODE" | grep -i x-app-version
