#!/bin/bash
# ============================================================================
# BASE VERSION — same tunnel mechanism as your original (kubectl port-forward)
# but with two fixes:
#   1. The sed injection into test/e2e-common.sh now only touches the FIRST
#      match of the anchor line, using the `0,/pattern/{...}` range trick.
#      Your original `/pattern/a\...` form inserts after EVERY match — if
#      "setup_ingress_env_vars" appears both as a function def and a call
#      site, you'd get the post-install-fix call injected twice, in the
#      wrong place, which can break e2e-common.sh's control flow well before
#      any test ever runs. That is a strong candidate for the
#      ImagePullBackOff/kapp-timeout you just hit.
#   2. Self-healing supervisor for the tunnel (active curl check, not just
#      "restart if the process died").
#
# Use this to confirm: does the kapp-timeout/ImagePullBackOff go away once
# the injection is fixed, with everything else unchanged? If yes, it was #1.
# If it still happens, it's the registry issue we discussed, unrelated to
# this script, and Option A / Option B (network topology) are moot until
# that's resolved.
# ============================================================================
set -uo pipefail   # NOT -e: many of the kubectl/kill calls are expected to
                    # fail intermittently and are already guarded with `|| true`

# Export USER before test starts
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

# Slow down kapp checks
sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh

# Reduce parallelism
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# Kourier replicas: 2 (cheap insurance; not the primary fix, see prior discussion)
sed -i 's/\(.*replicas: \).*/\12/' test/config/ytt/ingress/kourier/kourier-replicas.yaml

# --- DIAGNOSTIC: how many times does the injection anchor appear? ---
# This tells you, before anything else runs, whether the double-insertion
# risk is real in your current checkout of test/e2e-common.sh.
ANCHOR_COUNT=$(grep -c "setup_ingress_env_vars" test/e2e-common.sh || true)
echo ">>> DIAGNOSTIC: 'setup_ingress_env_vars' appears ${ANCHOR_COUNT} time(s) in test/e2e-common.sh"
if [[ "${ANCHOR_COUNT}" -gt 1 ]]; then
  echo ">>> DIAGNOSTIC: multiple matches found — using range-restricted sed so"
  echo ">>> only the FIRST match gets the injection (see below)."
fi

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

until kubectl get ns kourier-system >/dev/null 2>&1; do
  sleep 2
done

kubectl wait --for=condition=available deploy/3scale-kourier-gateway -n kourier-system --timeout=180s || true

kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl delete hpa webhook -n knative-serving --ignore-not-found || true
kubectl scale deployment activator --replicas=2 -n knative-serving || true

kubectl rollout status deployment/controller -n knative-serving --timeout=300s || true
kubectl rollout status deployment/autoscaler -n knative-serving --timeout=300s || true
kubectl rollout status deployment/activator -n knative-serving --timeout=300s || true

echo "Giving system time to stabilize..."
sleep 30

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

echo ">>> Starting Kourier port-forward supervisor (self-healing)..."
(
  trap 'exit 0' TERM INT

  HEALTH_INTERVAL=5
  MAX_FAILS=3
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

    if [[ -z "${PF_CHILD}" ]] || ! kill -0 "${PF_CHILD}" 2>/dev/null; then
      echo ">>> $(date) port-forward process died, restarting" >> /tmp/kourier-pf.log
      wait_for_svc
      PF_CHILD=$(start_pf)
      FAIL_COUNT=0
      continue
    fi

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

# --- FIXED: only insert after the FIRST match of the anchor line ---
# `0,/pattern/{...}` means: process lines from the start of the file up to
# (and including) the first line matching /pattern/, and only within that
# range apply the `a\` (append). Any later occurrence of the same string
# further down the file is left untouched.
sed -i '0,/setup_ingress_env_vars/{/setup_ingress_env_vars/a\
echo ">>> Running post-install fixes..." ; /tmp/post-install-fix.sh
}' test/e2e-common.sh

# --- DIAGNOSTIC: confirm exactly one injection landed ---
INJECTED_COUNT=$(grep -c "Running post-install fixes" test/e2e-common.sh || true)
echo ">>> DIAGNOSTIC: post-install-fix injected ${INJECTED_COUNT} time(s) into test/e2e-common.sh"
if [[ "${INJECTED_COUNT}" -ne 1 ]]; then
  echo "!!! WARNING: expected exactly 1 injection, found ${INJECTED_COUNT}." >&2
  echo "!!! Inspect test/e2e-common.sh manually before trusting this run." >&2
fi

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

sed -i '/(( failed )) && fail_test/i\source /tmp/kourier-cleanup.sh' test/e2e-tests.sh
sed -i '/^success$/i\source /tmp/kourier-cleanup.sh' test/e2e-tests.sh

# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml
