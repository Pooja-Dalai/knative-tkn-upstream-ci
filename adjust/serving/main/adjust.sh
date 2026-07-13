#!/bin/bash
set -e

echo ">>> Applying Knative Serving test adjustments"

# Export required variables before tests start.
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

# Slow down kapp readiness checks for PowerVS.
if ! grep -q -- "--wait-check-interval=45s" test/e2e-common.sh; then
  sed -i \
    's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' \
    test/e2e-common.sh
fi

# Reduce Go test parallelism.
sed -i \
  's/^\(parallelism=\).*/\1"-parallel 1"/' \
  test/e2e-tests.sh

# Use one Kourier gateway replica.
sed -i \
  's/\(.*replicas: \).*/\11/' \
  test/config/ytt/ingress/kourier/kourier-replicas.yaml

# -------------------------------------------------------------------
# Apply loopback patch
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# Post-install stabilization
# -------------------------------------------------------------------
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
  echo ">>> Dumping cluster state"

  kubectl get nodes -o wide || true
  kubectl get pods -n "${KNATIVE_NS}" -o wide || true
  kubectl get pods -n "${KOURIER_NS}" -o wide || true
  kubectl get deployments -n "${KNATIVE_NS}" || true
  kubectl get deployments -n "${KOURIER_NS}" || true
  kubectl get svc,endpoints -n "${KOURIER_NS}" || true
  kubectl get events -n "${KNATIVE_NS}" \
    --sort-by='.lastTimestamp' | tail -50 || true
  kubectl get events -n "${KOURIER_NS}" \
    --sort-by='.lastTimestamp' | tail -50 || true
}

stop_port_forward() {
  if [[ -f "${PF_CHILD_PID_FILE}" ]]; then
    CHILD_PID="$(cat "${PF_CHILD_PID_FILE}" 2>/dev/null || true)"
    kill "${CHILD_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${CHILD_PID}" 2>/dev/null || true
    rm -f "${PF_CHILD_PID_FILE}"
  fi

  if [[ -f "${PF_PID_FILE}" ]]; then
    SUPERVISOR_PID="$(cat "${PF_PID_FILE}" 2>/dev/null || true)"
    kill "${SUPERVISOR_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${SUPERVISOR_PID}" 2>/dev/null || true
    rm -f "${PF_PID_FILE}"
  fi

  pkill -f "kubectl port-forward.*31470" 2>/dev/null || true
}

echo ">>> Starting post-install stabilization"

# Wait for required namespaces.
for namespace in "${KNATIVE_NS}" "${KOURIER_NS}"; do
  echo ">>> Waiting for namespace ${namespace}"

  for attempt in $(seq 1 120); do
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      break
    fi

    if [[ "${attempt}" -eq 120 ]]; then
      echo "ERROR: Namespace ${namespace} was not created"
      dump_state
      exit 1
    fi

    sleep 5
  done
done

# Remove chaosduck if it remains from an earlier test setup.
kubectl delete deployment chaosduck \
  -n "${KNATIVE_NS}" \
  --ignore-not-found=true || true

# HA tests require more than one activator replica.
# Delete only the activator HPA so it does not scale the deployment back.
kubectl delete hpa activator \
  -n "${KNATIVE_NS}" \
  --ignore-not-found=true || true

kubectl scale deployment activator \
  -n "${KNATIVE_NS}" \
  --replicas=2

# Wait for all core Serving components.
for deployment in controller webhook autoscaler activator; do
  echo ">>> Waiting for ${KNATIVE_NS}/${deployment}"

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

# Wait until all currently running platform pods are Ready.
echo ">>> Waiting for Knative Serving pods"

if ! kubectl wait pod \
    -n "${KNATIVE_NS}" \
    --field-selector=status.phase=Running \
    --for=condition=Ready \
    --all \
    --timeout=10m; then
  dump_state
  exit 1
fi

echo ">>> Waiting for Kourier pods"

if ! kubectl wait pod \
    -n "${KOURIER_NS}" \
    --field-selector=status.phase=Running \
    --for=condition=Ready \
    --all \
    --timeout=10m; then
  dump_state
  exit 1
fi

# Wait for the Kourier service to have at least one ready endpoint.
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
    break
  fi

  if [[ "${attempt}" -eq 120 ]]; then
    echo "ERROR: Kourier service has no ready endpoints"
    dump_state
    exit 1
  fi

  sleep 5
done

# -------------------------------------------------------------------
# Stable Kourier port-forward supervisor
# -------------------------------------------------------------------
echo ">>> Cleaning old Kourier port-forwards"
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

# Do not start tests until the local ingress ports are listening.
for port in 31470 31475; do
  echo ">>> Waiting for local ingress port ${port}"

  for attempt in $(seq 1 90); do
    if timeout 2 bash -c \
        "</dev/tcp/127.0.0.1/${port}" \
        >/dev/null 2>&1; then
      echo ">>> Local ingress port ${port} is ready"
      break
    fi

    if [[ "${attempt}" -eq 90 ]]; then
      echo "ERROR: Local ingress port ${port} did not become ready"
      cat "${PF_LOG}" || true
      dump_state
      exit 1
    fi

    sleep 2
  done
done

# Verify that the HTTP connection is not being reset.
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
  echo "ERROR: Kourier ingress connectivity check failed"
  cat "${PF_LOG}" || true
  dump_state
  exit 1
fi

echo ">>> Kourier returned HTTP ${HTTP_CODE}"
echo ">>> Allowing controllers and informers to stabilize"
sleep 60

echo ">>> Post-install stabilization completed"
EOF

chmod +x /tmp/post-install-fix.sh

# Run post-install stabilization after ingress environment setup.
POST_INSTALL_COMMAND='echo ">>> Running post-install fixes..." ; /tmp/post-install-fix.sh'

if ! grep -Fq "${POST_INSTALL_COMMAND}" test/e2e-common.sh; then
  sed -i \
    "/setup_ingress_env_vars/a\\${POST_INSTALL_COMMAND}" \
    test/e2e-common.sh
fi

# -------------------------------------------------------------------
# Cleanup script
# -------------------------------------------------------------------
cat <<'EOF' > /tmp/kourier-cleanup.sh
#!/bin/bash
set +e

PF_PID_FILE="/tmp/kourier-portforward.pid"
PF_CHILD_PID_FILE="/tmp/kourier-portforward-child.pid"

echo ">>> Cleaning Kourier port-forward processes"

if [[ -f "${PF_CHILD_PID_FILE}" ]]; then
  CHILD_PID="$(cat "${PF_CHILD_PID_FILE}" 2>/dev/null || true)"
  kill "${CHILD_PID}" 2>/dev/null || true
  sleep 1
  kill -9 "${CHILD_PID}" 2>/dev/null || true
  rm -f "${PF_CHILD_PID_FILE}"
fi

if [[ -f "${PF_PID_FILE}" ]]; then
  SUPERVISOR_PID="$(cat "${PF_PID_FILE}" 2>/dev/null || true)"
  kill "${SUPERVISOR_PID}" 2>/dev/null || true
  sleep 1
  kill -9 "${SUPERVISOR_PID}" 2>/dev/null || true
  rm -f "${PF_PID_FILE}"
fi

pkill -f "kubectl port-forward.*31470" 2>/dev/null || true
EOF

chmod +x /tmp/kourier-cleanup.sh

# Run cleanup on failure.
if ! grep -Fq "source /tmp/kourier-cleanup.sh" test/e2e-tests.sh; then
  sed -i \
    '/(( failed )) && fail_test/i\source /tmp/kourier-cleanup.sh' \
    test/e2e-tests.sh

  sed -i \
    '/^success$/i\source /tmp/kourier-cleanup.sh' \
    test/e2e-tests.sh
fi

# -------------------------------------------------------------------
# Place the ppc64le overlay
# -------------------------------------------------------------------
if [[ ! -f /tmp/overlay-ppc64le.yaml ]]; then
  echo "ERROR: /tmp/overlay-ppc64le.yaml was not found"
  exit 1
fi

cp \
  /tmp/overlay-ppc64le.yaml \
  test/config/ytt/core/overlay-ppc64le.yaml

echo ">>> Knative Serving adjustments completed"
