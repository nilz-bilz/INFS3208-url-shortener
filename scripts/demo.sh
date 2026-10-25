#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# URL shortener: live demo script (INFS3208, Type I project)
#
# Author:         Nihal Singh Atwal
# Student ID:     49299175
# Email:          nihalsingh.atwal@student.uq.edu.au
# AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
#
# What this demonstrates (the Kubernetes marking criteria), one step each:
#   2 Load balancing    requests to one short link are answered by different redirect pods
#   3 Manual scaling    kubectl scale changes the shortener replica count
#   4 Autoscaling       the HPA adds redirect pods when CPU load rises
#   5 Reliability       deleting every redirect pod causes no failed requests
#   6 Rollout           a rolling update to v2 with zero failed requests
#   7 Rollback          rollout undo returns to v1
# Every command is printed (prefixed with "$") with a one-line description before it runs.
#
# Prerequisites
#   - Tools: bash, curl, python3, kubectl. Optional: hey (load generator; a curl/xargs fallback is used).
#   - kubectl points at the target cluster:  kubectl config current-context
#   - The app is deployed (kind: ./scripts/deploy-local.sh v1, GKE: ./scripts/deploy-gke.sh v1),
#     all pods are Ready and `kubectl get hpa -n urlshortener` shows a CPU %, not <unknown>.
#   - The demo data is loaded (user demo / demo1234):
#       kubectl exec -i deploy/shortener -n urlshortener -- python - < scripts/seed.py
#   - A v2 image of redirect exists where the cluster can pull it
#       kind: ./scripts/build.sh v2, then load it with `kind load image-archive` (see README)
#       GKE:  push <registry>/redirect:v2 (see README)
#   - Wait about 5 minutes after a previous load test so the HPA is back at 3 replicas.
#
# Usage:  ./scripts/demo.sh [CODE]
#   CODE         short code to use (default: first non-expiring link of the demo user)
# Environment:
#   HOST         public address of the app (default http://localhost:8080)
#   REDIRECT_V2  image for the rollout step (default localhost/redirect:v2)
#   NOPAUSE=1    do not wait for Enter between steps
# ------------------------------------------------------------------------------
set -euo pipefail

HOST="${HOST:-http://localhost:8080}"
REDIRECT_V2="${REDIRECT_V2:-localhost/redirect:v2}"
NS=urlshortener
LOOP_OUT="$(mktemp)"        # status codes written by the background request loop
LOOP_PID=""

# Stop background jobs and remove the temp file on exit
trap 'kill $(jobs -p) 2>/dev/null || true; rm -f "$LOOP_OUT"' EXIT

# ---- output helpers ----------------------------------------------------------

# Print a step heading and wait for Enter (skipped when NOPAUSE=1)
step() {
  echo
  echo "=============================================================="
  echo "STEP $1"
  echo "=============================================================="
  if [ -z "${NOPAUSE:-}" ]; then read -rp "Press Enter to start... "; fi
}

# Print "# description" and "$ command", then run the command
run() {
  printf '\n# %s\n$ %s\n' "$1" "$2"
  eval "$2"
}

# Same as run, but in the background
run_bg() {
  printf '\n# %s (background)\n$ %s\n' "$1" "$2"
  eval "$2" &
}

# ---- request loop (used by steps 5 and 6) -----------------------------------

# Request the short link every 0.2 s in the background, recording each HTTP status code (-m 3: a hang counts as 000)
start_loop() {
  printf '\n# Send a request every 0.2 s in the background and record the status codes (000 = timeout)\n'
  printf '$ while true; do curl -s -m 3 -o /dev/null -w "%%{http_code}\\n" %s/%s; sleep 0.2; done\n' "$HOST" "$CODE"
  ( while true; do curl -s -m 3 -o /dev/null -w "%{http_code}\n" "$HOST/$CODE" >> "$LOOP_OUT"; sleep 0.2; done ) &
  LOOP_PID=$!
}

# Stop the loop and count the status codes it saw
stop_loop() {
  kill "$LOOP_PID" 2>/dev/null || true
  wait "$LOOP_PID" 2>/dev/null || true
  run "Count the status codes seen during the step (expect only 302)" "sort $LOOP_OUT | uniq -c"
  : > "$LOOP_OUT"
}

# ---- setup ------------------------------------------------------------------

# Fail early with a clear message if kubectl cannot reach the app
preflight() {
  echo "Cluster: $(kubectl config current-context)"
  echo "Target:  $HOST"
  kubectl get deploy redirect -n "$NS" >/dev/null || { echo "redirect Deployment not found in $NS; deploy first."; exit 1; }
}

# Use the given short code, or log in as the demo user and take its first non-expiring link
resolve_code() {
  if [ -n "${1:-}" ]; then CODE="$1"; return; fi
  local token
  token=$(curl -s -d '{"username":"demo","password":"demo1234"}' -H 'Content-Type: application/json' "$HOST/api/auth/login" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
  CODE=$(curl -s -H "Authorization: Bearer $token" "$HOST/api/links" \
    | python3 -c 'import sys,json; print(next(l for l in json.load(sys.stdin) if not l["expires_at"])["code"])')
}

# ---- demo steps -------------------------------------------------------------

demo_tour() {
  step "1: App tour (browser)"
  echo "Open $HOST/ui/, log in as demo / demo1234, create a link, open it, show the stats dialog, QR code and top links."
}

demo_load_balancing() {
    step "2: Load balancing (traffic from different pods)"
  run "Six requests to the same link; the X-Served-By pod name should vary" \
      "for i in 1 2 3 4 5 6; do curl -sI $HOST/$CODE | grep -i x-served-by; done"
}

demo_manual_scaling() {
  step "3: Manual scaling"
  run "Scale the shortener Deployment to 4 replicas" "kubectl scale deploy/shortener --replicas=4 -n $NS"
  run "Wait until all 4 are available" "kubectl rollout status deploy/shortener -n $NS --timeout=120s"
  run "List the shortener pods" "kubectl get pods -n $NS -l app=shortener"
  run "Scale back to 2 so the demo can be re-run" "kubectl scale deploy/shortener --replicas=2 -n $NS"
  sleep 10
  run "List the shortener pods" "kubectl get pods -n $NS -l app=shortener"
}

demo_autoscaling() {
  step "4: Autoscaling"
  if command -v hey >/dev/null 2>&1; then
    run_bg "Generate 45 s of load with 50 workers (hey -z duration, -c workers, -disable-redirects)" \
           "hey -z 45s -c 50 -disable-redirects $HOST/$CODE >/dev/null"
  else
    run_bg "Generate 45 s of load with 60 parallel curls (hey is not installed)" \
           "timeout 45 bash -c 'while true; do seq 200 | xargs -P 60 -I{} curl -s -o /dev/null $HOST/$CODE; done'"
  fi
  run "Watch the HPA every 10 s: CPU % should pass 50% and REPLICAS should rise above 3" \
      "for i in 1 2 3 4 5; do sleep 10; kubectl get hpa redirect -n $NS; done"
  wait   # let the load generator finish
}

demo_reliability() {
  step "5: Reliability"
  start_loop
  sleep 5
  run "Delete every redirect pod at once; the Deployment recreates them" \
      "kubectl delete pod -l app=redirect -n $NS --wait=false"
  run "Give the replacements time to become Ready" "sleep 25"
  stop_loop
  echo "Pick a node that does not run mysql-0 (find it with: kubectl get pods -n $NS -o wide)."
}

demo_rollout() {
  step "6: Rolling update to v2"
  start_loop
  sleep 3
  run "Switch the redirect container to the v2 image; the rolling update keeps pods serving" \
      "kubectl set image deploy/redirect redirect=$REDIRECT_V2 -n $NS"
  run "Record the reason so rollout history is readable" \
      "kubectl annotate deploy/redirect kubernetes.io/change-cause=v2 -n $NS --overwrite"
  run "Wait for the rollout to finish" "kubectl rollout status deploy/redirect -n $NS --timeout=420s"
  stop_loop
  run "The version header should now say v2" "curl -sI $HOST/$CODE | grep -i x-app-version"
}

demo_rollback() {
  step "7: Rollback"
  run "Show the revision history" "kubectl rollout history deploy/redirect -n $NS"
  run "Roll back to the previous revision" "kubectl rollout undo deploy/redirect -n $NS"
  run "Wait for the rollback to finish" "kubectl rollout status deploy/redirect -n $NS --timeout=420s"
  run "Relabel the revision (undo copies the old label)" \
      "kubectl annotate deploy/redirect kubernetes.io/change-cause='rollback to v1' -n $NS --overwrite"
  run "The version header should be back to v1 (may take a few seconds on GKE)" \
      "sleep 10; curl -sI $HOST/$CODE | grep -i x-app-version"
}

# ---- main -------------------------------------------------------------------

main() {
  preflight
  resolve_code "${1:-}"
  echo "Using short link: $HOST/$CODE"
  demo_tour
  demo_load_balancing
  demo_manual_scaling
  demo_autoscaling
  demo_reliability
  demo_rollout
  demo_rollback
  echo; echo "Demo complete."
}

main "$@"
