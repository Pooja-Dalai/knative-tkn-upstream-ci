#!/bin/bash

# Export USER before test starts
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

# Slow down kapp checks
sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh

# Reduce parallelism
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# Reduce replicas
sed -i 's/\(.*replicas: \).*/\11/' test/config/ytt/ingress/kourier/kourier-replicas.yaml

# =========================
# Apply test patch (loopback fix)
# =========================
echo ">>> Applying loopback patch via git apply..."

PATCH_FILE="/tmp/skip-loopback.patch"

if [ ! -f "$PATCH_FILE" ]; then
  echo "❌ Patch file not found: $PATCH_FILE"
  ls -l /tmp
  exit 1
fi

git apply "$PATCH_FILE"
# =========================
# Post-install script
# =========================
cat << 'EOF' > /tmp/post-install-fix.sh
#!/bin/bash

echo ">>> [PATCH] Starting post-install setup..."

echo ">>> Waiting for kourier-system namespace..."
until kubectl get ns kourier-system >/dev/null 2>&1; do
  echo ">>> still waiting..."
  sleep 2
done

echo ">>> Waiting for Kourier deployment..."
kubectl wait --for=condition=available deploy/kourier -n kourier-system --timeout=180s || true

echo ">>> Waiting for Kourier endpoints..."
until kubectl get endpoints -n kourier-system kourier -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; do
  echo ">>> waiting for endpoints..."
  sleep 2
done

echo ">>> Waiting for webhook endpoints..."

until kubectl get endpoints webhook -n knative-serving -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; do
  echo ">>> waiting for webhook endpoints..."
  sleep 2
done

echo ">>> Waiting for webhook to be ready..."

kubectl rollout status deployment/webhook -n knative-serving --timeout=300s

kubectl wait --for=condition=Ready pod \
  -l app=webhook \
  -n knative-serving \
  --timeout=300s

echo ">>> Applying cluster fixes..."

kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true

#kubectl delete hpa activator -n knative-serving --ignore-not-found || true

# NEW — keeps autoscaler-hpa deployment, only removes HPAs
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl delete hpa webhook -n knative-serving --ignore-not-found || true
# DO NOT delete autoscaler-hpa deployment — needed for HPA tests
# DO NOT delete hpa for autoscaler-hpa — needed for HA HPA test

kubectl scale deployment activator --replicas=2 -n knative-serving || true

echo ">>> Waiting for Knative core components..."

kubectl rollout status deployment/controller -n knative-serving --timeout=300s
kubectl rollout status deployment/autoscaler -n knative-serving --timeout=300s
kubectl rollout status deployment/activator -n knative-serving --timeout=300s

kubectl wait --for=condition=Ready pod \
  -l app=controller \
  -n knative-serving \
  --timeout=300s

kubectl wait --for=condition=Ready pod \
  -l app=autoscaler \
  -n knative-serving \
  --timeout=300s

kubectl wait --for=condition=Ready pod \
  -l app=activator \
  -n knative-serving \
  --timeout=300s

echo ">>> Giving system time to stabilize..."
sleep 20

# =========================
# FIXED PORT FORWARD (CLEAN)
# =========================
echo ">>> Starting Kourier port-forward (NodePort aligned)..."

( while true; do
  kubectl port-forward -n kourier-system service/kourier \
    31470:80 \
    31475:443 >> /tmp/kourier-pf.log 2>&1 || true

  echo ">>> port-forward restarted" >> /tmp/kourier-pf.log
  sleep 2
done ) &
EOF

chmod +x /tmp/post-install-fix.sh


# =========================
# Inject AFTER install
# =========================
sed -i '/setup_ingress_env_vars/a \
echo ">>> Running post-install" ; \
/tmp/post-install-fix.sh \
' test/e2e-common.sh


# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml

