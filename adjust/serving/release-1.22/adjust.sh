#!/bin/bash
# Export USER before test starts
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

# Slow down kapp checks
sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh

# Reduce parallelism
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# --- CHANGED ---
# Was: forced to 1 replica, making Kourier's Envoy gateway a single point of
# failure for the ENTIRE e2e run (every test's traffic goes through one pod).
# Now: keep 2 replicas so the gateway Service always has a healthy endpoint
# for the port-forward tunnel to fail over to.
sed -i 's/\(.*replicas: \).*/\12/' test/config/ytt/ingress/kourier/kourier-replicas.yaml

# Apply test patch (loopback fix)
echo "Applying loopback patch"
PATCH_FILE="/tmp/skip-loopback.patch"
if [ ! -f "$PATCH_FILE" ]; then
  echo "Patch file not found: $PATCH_FILE"
  exit 1
fi
git apply "$PATCH_FILE"

# Post-install script
cat << 'EOF' > /tmp/post-install-fix.sh
#!/bin/bash
set +e
echo "Starting post-install setup..."

# Wait for Kourier namespace and gateway deployment before starting tests.
until kubectl get ns kourier-system >/dev/null 2>&1; do
  sleep 2
done

kubectl wait --for=condition=available deploy/3scale-kourier-gateway -n kourier-system --timeout=180s || true

# Applying cluster fixes
kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl delete hpa webhook -n knative-serving --ignore-not-found || true
kubectl scale deployment activator --replicas=2 -n knative-serving || true

# Waiting for Knative core components
kubectl rollout status deployment/controller -n knative-serving --timeout=300s || true
kubectl rollout status deployment/autoscaler -n knative-serving --timeout=300s || true
kubectl rollout status deployment/activator -n knative-serving --timeout=300s || true

echo "Giving system time to stabilize..."
sleep 30

# Cleanup old forwards before starting a new one
echo ">>> Cleaning up old Kourier port-forwards..."
if [[ -f /tmp/kourier-portforward.pid ]]; then
  OLD_PID=$(cat /tmp/kourier-portforward.pid)
  kill "${OLD_PID}" 2>/dev/null || true
  sleep 2
  kill -9 "${OLD_PID}" 2>/dev/null || true
  rm -f /tmp/kourier-portforward.pid
fi
pkill -f "port-forward.*kourier" 2>/dev/null || true
sleep 2

# --- CHANGED ---
# Was: supervisor only restarted the tunnel when the kubectl process itself
# exited. A tunnel that goes stale/stuck under load (very common with
# kubectl port-forward, which is API-server-proxied and not built for
# sustained/high-concurrency throughput) never got detected, so every test
# hitting it during that window failed with "connection reset by peer" /
# "context deadline exceeded" until the process eventually crashed on its own.
# Now: an active curl-based health check runs every few seconds. If the
# tunnel stops actually answering HTTP requests (not just "process alive"),
# it's force-killed and restarted immediately, shrinking the outage window
# from "however long until the process happens to die" to a few seconds.
echo ">>> Starting Kourier port-forward supervisor (self-healing)..."
(
  trap 'exit 0' TERM INT

  HEALTH_INTERVAL=5     # seconds between health checks
  MAX_FAILS=3           # consecutive failed checks before forcing a restart
  FAIL_COUNT=0

  start_pf() {
    kubectl get svc kourier -n kourier-system >/dev/null 2>&1 || return 1
    kubectl port-forward \
      -n kourier-system \
      service/kourier \
      31470:80 \
      31475:443 \
      >> /tmp/kourier-pf.log 2>&1 &
    echo $!
  }

  wait_for_svc() {
    until kubectl get svc kourier -n kourier-system >/dev/null 2>&1; do
      sleep 5
    done
  }

  wait_for_svc
  echo ">>> $(date) starting port-forward" >> /tmp/kourier-pf.log
  PF_CHILD=$(start_pf)

  while true; do
    sleep "${HEALTH_INTERVAL}"

    # Is the tunnel process still alive?
    if [[ -z "${PF_CHILD}" ]] || ! kill -0 "${PF_CHILD}" 2>/dev/null; then
      echo ">>> $(date) port-forward process died, restarting" >> /tmp/kourier-pf.log
      wait_for_svc
      PF_CHILD=$(start_pf)
      FAIL_COUNT=0
      continue
    fi

    # Active health check: does the tunnel actually serve traffic end-to-end?
    # Any HTTP response (even 404) proves the local socket, the API-server
    # proxy, and the Envoy pod behind it are all still working.
    CODE=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:31470/ 2>/dev/null)
    if [[ "${CODE}" =~ ^[0-9]+$ ]]; then
      FAIL_COUNT=0
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo ">>> $(date) health check failed (${FAIL_COUNT}/${MAX_FAILS})" >> /tmp/kourier-pf.log
    fi

    if [[ "${FAIL_COUNT}" -ge "${MAX_FAILS}" ]]; then
      echo ">>> $(date) tunnel unhealthy after ${MAX_FAILS} checks, forcing restart" >> /tmp/kourier-pf.log
      kill "${PF_CHILD}" 2>/dev/null || true
      sleep 1
      kill -9 "${PF_CHILD}" 2>/dev/null || true
      wait_for_svc
      PF_CHILD=$(start_pf)
      FAIL_COUNT=0
    fi
  done
) &
PF_PID=$!
echo "${PF_PID}" > /tmp/kourier-portforward.pid
echo ">>> Port-forward supervisor PID=${PF_PID}"
EOF
chmod +x /tmp/post-install-fix.sh

# Run post-install fixes after ingress environment variables are configured
sed -i '/setup_ingress_env_vars/a\echo ">>> Running post-install fixes..." ; /tmp/post-install-fix.sh' test/e2e-common.sh

# Cleanup script
cat <<'EOF' > /tmp/kourier-cleanup.sh
#!/bin/bash
set +e
if [[ -f /tmp/kourier-portforward.pid ]]; then
  PID=$(cat /tmp/kourier-portforward.pid)
  kill "${PID}" 2>/dev/null || true
  sleep 2
  kill -9 "${PID}" 2>/dev/null || true
  rm -f /tmp/kourier-portforward.pid
fi
pkill -f "port-forward.*kourier" 2>/dev/null || true
sleep 2
EOF
chmod +x /tmp/kourier-cleanup.sh

# Cleanup on failure and success
sed -i '/(( failed )) && fail_test/i\source /tmp/kourier-cleanup.sh' test/e2e-tests.sh
sed -i '/^success$/i\source /tmp/kourier-cleanup.sh' test/e2e-tests.sh

# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml
