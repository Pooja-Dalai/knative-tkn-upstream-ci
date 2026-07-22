#!/bin/bash
# ============================================================================
# adjust.sh -- restructured to mirror the s390x (z) team's working script
# logic as closely as possible, with only the deltas required by our system:
#
#   - We do NOT create the namespace, install/patch metrics-server, or
#     create registry secrets here -- setup-environment.sh already does all
#     of that before this script runs. Their script does it inline because
#     their pipeline invokes it standalone, without an equivalent separate
#     setup step. Copying that part over would be pure redundancy.
#   - We do NOT docker login / clone knative/serving / set KO_DOCKER_REPO
#     etc. here -- our pipeline's Prow job decoration already checks out the
#     repo and this script runs from inside it. Their script does its own
#     clone because it's a fully standalone step.
#   - We do NOT export TEST_OPTIONS or call ./test/e2e-tests.sh at the end --
#     both already live in our serving job yaml, confirmed in an earlier
#     pass. Their script does both inline because, again, it's the one and
#     only step in their pipeline.
#   - Port numbers in the forward (31470/31475) match OUR Kourier NodePort
#     config and TEST_OPTIONS ingressendpoint, confirmed from our own
#     cluster's `kubectl get svc kourier` output -- not copied verbatim from
#     their script, since their NodePort values (30080/30443) come from
#     their own overlay-s390x.yaml, which is specific to their setup.
#
# Everything else below -- the patch sequence, the loopback patch
# application, and critically the PORT FORWARDING LOGIC -- mirrors their
# script exactly: same function names, same flat/sequential structure, same
# restart-on-process-death-only loop (no added active health check). This is
# intentional: you asked to copy their working logic as-is rather than layer
# more on top of it.
#
# Invocation assumption (confirmed from our own Prow trace log): this script
# is SOURCED (`. /tmp/adjust.sh`), not executed as its own subprocess. That's
# what lets the background port-forward loop below stay alive into the same
# shell that later runs ./test/e2e-tests.sh, exactly like it does for them.
# ============================================================================
set -uo pipefail   # NOT -e: several kubectl/kill calls are expected to fail
                    # intermittently and are already guarded with `|| true`

# ---------------------------------------------------------------------------
# Standard repo patches (unchanged from our original)
# ---------------------------------------------------------------------------
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# Kourier replicas: 1 -- matched to their value. Earlier we bumped this to 2
# as a precaution, but since their script also runs with 1 replica and works
# fine, that precaution wasn't earning its keep; matching them removes an
# unnecessary difference.
sed -i 's/\(.*replicas: \).*/\11/' test/config/ytt/ingress/kourier/kourier-replicas.yaml

# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml

# Apply loopback-skip patch (unchanged from our original)
echo ">>> Applying loopback patch..."
PATCH_FILE="/tmp/skip-loopback.patch"
if [ ! -f "$PATCH_FILE" ]; then
  echo "Patch file not found: $PATCH_FILE"
  exit 1
fi
git apply "$PATCH_FILE"

# ---------------------------------------------------------------------------
# Post-install cluster fixes -- kept flat (not wrapped in a function) to
# match their style. These specific steps (kourier-ns wait, gateway wait,
# webhook HPA cleanup, rollout status waits) predate any of our changes --
# they were already in our original adjust.sh and are relevant to our
# multi-node PowerVS cluster (slower to stabilize than their single-node
# Kind setup), so they're kept rather than dropped for style parity alone.
# ---------------------------------------------------------------------------
echo ">>> Running post-install fixes..."

until kubectl get ns kourier-system >/dev/null 2>&1; do
  sleep 2
done
kubectl wait --for=condition=available deploy/3scale-kourier-gateway -n kourier-system --timeout=180s || true

echo ">>> Cleaning up chaosduck if present..."
kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true

echo ">>> Deleting Activator/Webhook HPA to prevent auto-scaling..."
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl delete hpa webhook -n knative-serving --ignore-not-found || true
# NOTE: kept at 2 (not matched to their replicas=1) -- this predates any of
# our changes, was already in our original adjust.sh before the tunnel work
# started, and is unrelated to it. Flagging so it's a visible, intentional
# choice rather than an accidental leftover.
kubectl scale deployment activator --replicas=2 -n knative-serving || true

kubectl rollout status deployment/controller -n knative-serving --timeout=300s || true
kubectl rollout status deployment/autoscaler -n knative-serving --timeout=300s || true
kubectl rollout status deployment/activator -n knative-serving --timeout=300s || true

echo ">>> Giving system time to stabilize..."
sleep 30

# ---------------------------------------------------------------------------
# PORT FORWARDING FUNCTIONS -- mirrors their logic exactly: restart on
# process death only, no active health check layered on top.
# ---------------------------------------------------------------------------
PF_LOOP_PID=""

cleanup_port_forward() {
  echo ">>> Cleaning up port forwarding..."
  if [ -n "$PF_LOOP_PID" ]; then
    kill "$PF_LOOP_PID" 2>/dev/null || true
  fi
  pkill -9 -f "port-forward.*kourier" || true
}

start_robust_port_forward() {
  local namespace=$1
  local service=$2
  shift 2
  local ports=("$@")

  echo ">>> Starting robust port forwarding for service/$service in namespace $namespace..."

  pkill -9 -f "port-forward.*$service" || true

  (
    echo ">>> Waiting for service $service in namespace $namespace to exist before forwarding..."
    while ! kubectl get service "$service" -n "$namespace" >/dev/null 2>&1; do
      sleep 5
    done
    echo ">>> Service $service found. Starting port-forward in background (logging to /tmp/port-forward.log)."

    while true; do
      echo ">>> [$(date)] Launching kubectl port-forward for $service..." >> /tmp/port-forward.log
      kubectl port-forward -n "$namespace" service/"$service" "${ports[@]}" >> /tmp/port-forward.log 2>&1 &

      PF_PID=$!
      echo ">>> [$(date)] Port forward PID: $PF_PID" >> /tmp/port-forward.log

      wait "$PF_PID" || true

      echo ">>> [$(date)] Port forward process (PID $PF_PID) died/exited. Restarting in 2 seconds..." >> /tmp/port-forward.log
      sleep 2
    done
  ) &

  PF_LOOP_PID=$!
  echo ">>> Port forwarding loop started with PID: $PF_LOOP_PID"
}

# Trap cleanup on exit
trap cleanup_port_forward EXIT SIGINT SIGTERM

# Start port forwarding -- ports match OUR Kourier NodePort config
# (31470/31475), not their literal values.
start_robust_port_forward "kourier-system" "kourier" "31470:80" "31475:443"

# Non-blocking check - the loop above will eventually connect once Kourier
# is installed by e2e-tests.sh
echo ">>> Port forwarding started in background. It will connect once Kourier is ready."

# NOTE: TEST_OPTIONS (including --ingressendpoint) and the
# ./test/e2e-tests.sh invocation are both already handled in the serving job
# yaml elsewhere in our pipeline -- intentionally not duplicated here.
