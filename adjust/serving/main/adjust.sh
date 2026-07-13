#!/bin/bash
set -e

echo ">>> Applying Knative Serving ppc64le adjustments"

# ------------------------------------------------------------------
# Test configuration
# ------------------------------------------------------------------

# Export USER before test starts.
if ! grep -q 'export USER=' test/e2e-tests.sh; then
  sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
fi

# Enable the shorter test configuration.
if ! grep -q 'export SHORT=1' test/e2e-tests.sh; then
  sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh
fi

# Slow down kapp checks for PowerVS.
if ! grep -q -- '--wait-check-interval=45s' test/e2e-common.sh; then
  sed -i \
    's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' \
    test/e2e-common.sh
fi

# Reduce test parallelism.
sed -i \
  's/^\(parallelism=\).*/\1"-parallel 1"/' \
  test/e2e-tests.sh

# Use one Kourier gateway replica.
sed -i \
  's/\(.*replicas: \).*/\11/' \
  test/config/ytt/ingress/kourier/kourier-replicas.yaml

# ------------------------------------------------------------------
# Apply loopback patch
# ------------------------------------------------------------------

echo ">>> Applying loopback patch"

PATCH_FILE="/tmp/skip-loopback.patch"

if [[ ! -f "${PATCH_FILE}" ]]; then
  echo "ERROR: Patch file not found: ${PATCH_FILE}"
  exit 1
fi

if git apply --check "${PATCH_FILE}" >/dev/null 2>&1; then
  git apply "${PATCH_FILE}"
elif git apply --reverse --check "${PATCH_FILE}" >/dev/null 2>&1; then
  echo ">>> Loopback patch is already applied"
else
  echo "ERROR: Loopback patch cannot be applied cleanly"
  exit 1
fi

# ------------------------------------------------------------------
# Post-install readiness and Kourier port-forward
# ------------------------------------------------------------------

cat <<'EOF' > /tmp/post-install-fix.sh
#!/bin/bash
set -e

KNATIVE_NS="knative-serving"
KOURIER_NS="kourier-system"
KOURIER_DEPLOYMENT="3scale-kourier-gateway"

PF_PID_FILE="/tmp/kourier-portforward.pid"
PF_CHILD_PID_FILE="/tmp/kourier-portforward-child.pid"
PF_LOG="/tmp/kourier-pf.log"

dump_state() {
  echo ">>> Cluster state"

  kubectl get nodes -o wide || true
  kubectl get pods -n "${KNATIVE_NS}" -o wide || true
  kubectl get pods -n "${KOURIER_NS}" -o wide || true
  kubectl get deployments -n "${KNATIVE_NS}" || true
  kubectl get deployments -n "${KOURIER_NS}" || true
  kubectl get svc,endpoints -n "${KOURIER_NS}" || true

  echo ">>> Recent Knative Serving events"
  kubectl get events -n "${KNATIVE_NS}" \
    --sort-by='.lastTimestamp' | tail -50 || true

  echo ">>> Recent Kourier events"
  kubectl get events -n "${KOURIER_NS}" \
    --sort-by='.lastTimestamp' | tail -50 || true
}

stop_port_forward() {
  echo ">>> Stopping existing Kourier port-forward"

  if [[ -f "${PF_CHILD_PID_FILE}" ]]; then
    CHILD_PID="$(cat "${PF_CHILD_PID_FILE}" 2>/dev/null || true)"

    if [[ -n "${CHILD_PID}" ]]; then
      kill "${CHILD_PID}" 2>/dev/null || true
      sleep 1
      kill -9 "${CHILD_PID}" 2>/dev/null || true
    fi

    rm -f "${PF_CHILD_PID_FILE}"
  fi

  if [[ -f "${PF_PID_FILE}" ]]; then
    SUPERVISOR_PID="$(cat "${PF_PID_FILE}" 2>/dev/null || true)"

    if [[ -n "${SUPERVISOR_PID}" ]]; then
      kill "${SUPERVISOR_PID}" 2>/dev/null || true
      sleep 1
      kill -9 "${SUPERVISOR_PID}" 2>/dev/null || true
    fi

    rm -f "${PF_PID_FILE}"
  fi

  pkill -f "kubectl port-forward.*31470" 2>/dev/null || true
}

wait_for_namespace() {
  local namespace="$1"

  echo ">>> Waiting for namespace ${namespace}"

  for attempt in $(seq 1 120); do
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    sleep 5
  done

  echo "ERROR: Namespace ${namespace} was not created"
  return 1
}

wait_for_kourier_endpoint() {
  echo ">>> Waiting for Kourier endpoints"

  for attempt in $(seq 1 120); do
    ENDPOINTS="$(
      kubectl get endpoints kourier \
        -n "${KOURIER_NS}" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' \
        2>/dev/null || true
    )"

    if [[ -n "${ENDPOINTS}" ]]; then
      echo ">>> Kourier endpoints are ready: ${ENDPOINTS}"
      return 0
    fi

    sleep 5
  done

  echo "ERROR: Kourier has no ready endpoints"
  return 1
}

echo ">>> Starting post-install stabilization"

wait_for_namespace "${KNATIVE_NS}" || {
  dump_state
  exit 1
}

wait_for_namespace "${KOURIER_NS}" || {
  dump_state
  exit 1
}

# Remove chaosduck if it exists from an earlier setup.
kubectl delete deployment chaosduck \
  -n "${KNATIVE_NS}" \
  --ignore-not-found=true || true

# HA tests require more than one activator replica.
# Remove the activator HPA so it does not immediately scale it back.
kubectl delete hpa activator \
  -n "${KNATIVE_NS}" \
  --ignore-not-found=true || true

kubectl scale deployment activator \
  -n "${KNATIVE_NS}" \
  --replicas=2

# Do not delete the webhook HPA.

echo ">>> Waiting for Knative Serving deployments"

for deployment in controller webhook autoscaler activator; do
  echo ">>> Waiting for deployment ${deployment}"

  if ! kubectl rollout status \
      deployment/"${deployment}" \
      -n "${KNATIVE_NS}" \
      --timeout=10m; then
    dump_state
    exit 1
  fi
done

echo ">>> Waiting for Kourier gateway"

if ! kubectl rollout status \
    deployment/"${KOURIER_DEPLOYMENT}" \
    -n "${KOURIER_NS}" \
    --timeout=10m; then
  dump_state
  exit 1
fi

echo ">>> Waiting for Knative Serving pods to become Ready"

if ! kubectl wait pod \
    -n "${KNATIVE_NS}" \
    --field-selector=status.phase=Running \
    --for=condition=Ready \
    --all \
    --timeout=10m; then
  dump_state
  exit 1
fi

echo ">>> Waiting for Kourier pods to become Ready"

if ! kubectl wait pod \
    -n "${KOURIER_NS}" \
    --field-selector=status.phase=Running \
    --for=condition=Ready \
    --all \
    --timeout=10m; then
  dump_state
  exit 1
fi

wait_for_kourier_endpoint || {
  dump_state
  exit 1
}

# ------------------------------------------------------------------
# Start persistent Kourier port-forward
# ------------------------------------------------------------------

stop_port_forward
: > "${PF_LOG}"

echo ">>> Starting Kourier port-forward supervisor"

(
  trap '
    if [[ -n "${CHILD_PID:-}" ]]; then
      kill "${CHILD_PID}" 2>/dev/null || true
    fi
    exit 0
  ' TERM INT EXIT

  while true; do
    READY_REPLICAS="$(
      kubectl get deployment "${KOURIER_DEPLOYMENT}" \
        -n "${KOURIER_NS}" \
        -o jsonpath='{.status.readyReplicas}' \
        2>/dev/null || echo 0
    )"

    READY_REPLICAS="${READY_REPLICAS:-0}"

    if [[ "${READY_REPLICAS}" -lt 1 ]]; then
      echo ">>> $(date) Kourier has no ready replicas" >> "${PF_LOG}"
      sleep 5
      continue
    fi

    echo ">>> $(date) Starting Kourier port-forward" >> "${PF_LOG}"

    kubectl port-forward \
      -n "${KOURIER_NS}" \
      deployment/"${KOURIER_DEPLOYMENT}" \
      --address=127.0.0.1 \
      31470:8080 \
      31475:8443 \
      >> "${PF_LOG}" 2>&1 &

    CHILD_PID=$!
    echo "${CHILD_PID}" > "${PF_CHILD_PID_FILE}"

    wait "${CHILD_PID}" || true

    rm -f "${PF_CHILD_PID_FILE}"

    echo ">>> $(date) Kourier port-forward exited; restarting" \
      >> "${PF_LOG}"

    sleep 2
  done
) &

PF_PID=$!
echo "${PF_PID}" > "${PF_PID_FILE}"

echo ">>> Port-forward supervisor PID=${PF_PID}"

# Wait until both forwarded ports are listening.
for port in 31470 31475; do
  echo ">>> Waiting for local ingress port ${port}"

  PORT_READY=false

  for attempt in $(seq 1 90); do
    if timeout 2 bash -c \
        "</dev/tcp/127.0.0.1/${port}" \
        >/dev/null 2>&1; then
      PORT_READY=true
      break
    fi

    sleep 2
  done

  if [[ "${PORT_READY}" != "true" ]]; then
    echo "ERROR: Local ingress port ${port} did not become ready"
    cat "${PF_LOG}" || true
    dump_state
    exit 1
  fi

  echo ">>> Local ingress port ${port} is ready"
done

# Verify the HTTP connection stays open.
echo ">>> Checking Kourier HTTP connectivity"

HTTP_CODE="$(
  timeout 10 curl \
    --silent \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header 'Host: readiness-check.example.com' \
    http://127.0.0.1:31470/ \
    2>/dev/null || true
)"

if [[ ! "${HTTP_CODE}" =~ ^[1-5][0-9][0-9]$ ]]; then
  echo "ERROR: Kourier HTTP connectivity check failed"
  cat "${PF_LOG}" || true
  dump_state
  exit 1
fi

echo ">>> Kourier returned HTTP ${HTTP_CODE}"
echo ">>> Allowing Knative controllers to stabilize"
sleep 60

echo ">>> Post-install stabilization completed successfully"
EOF

chmod +x /tmp/post-install-fix.sh

# Run post-install fixes after ingress environment variables are configured.
POST_INSTALL_COMMAND='echo ">>> Running post-install fixes..." ; /tmp/post-install-fix.sh'

if ! grep -Fq '/tmp/post-install-fix.sh' test/e2e-common.sh; then
  sed -i \
    "/setup_ingress_env_vars/a\\${POST_INSTALL_COMMAND}" \
    test/e2e-common.sh
fi

# ------------------------------------------------------------------
# Cleanup script
# ------------------------------------------------------------------

cat <<'EOF' > /tmp/kourier-cleanup.sh
#!/bin/bash
set +e

PF_PID_FILE="/tmp/kourier-portforward.pid"
PF_CHILD_PID_FILE="/tmp/kourier-portforward-child.pid"

echo ">>> Cleaning Kourier port-forward processes"

if [[ -f "${PF_CHILD_PID_FILE}" ]]; then
  CHILD_PID="$(cat "${PF_CHILD_PID_FILE}" 2>/dev/null || true)"

  if [[ -n "${CHILD_PID}" ]]; then
    kill "${CHILD_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${CHILD_PID}" 2>/dev/null || true
  fi

  rm -f "${PF_CHILD_PID_FILE}"
fi

if [[ -f "${PF_PID_FILE}" ]]; then
  SUPERVISOR_PID="$(cat "${PF_PID_FILE}" 2>/dev/null || true)"

  if [[ -n "${SUPERVISOR_PID}" ]]; then
    kill "${SUPERVISOR_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${SUPERVISOR_PID}" 2>/dev/null || true
  fi

  rm -f "${PF_PID_FILE}"
fi

pkill -f "kubectl port-forward.*31470" 2>/dev/null || true
EOF

chmod +x /tmp/kourier-cleanup.sh

# Insert cleanup before test failure and success.
if ! grep -Fq 'source /tmp/kourier-cleanup.sh' test/e2e-tests.sh; then
  sed -i \
    '/(( failed )) && fail_test/i\source /tmp/kourier-cleanup.sh' \
    test/e2e-tests.sh

  sed -i \
    '/^success$/i\source /tmp/kourier-cleanup.sh' \
    test/e2e-tests.sh
fi

# ------------------------------------------------------------------
# Place ppc64le overlay
# ------------------------------------------------------------------

if [[ ! -f /tmp/overlay-ppc64le.yaml ]]; then
  echo "ERROR: /tmp/overlay-ppc64le.yaml was not found"
  exit 1
fi

cp \
  /tmp/overlay-ppc64le.yaml \
  test/config/ytt/core/overlay-ppc64le.yaml

echo ">>> Knative Serving adjustments completed"
