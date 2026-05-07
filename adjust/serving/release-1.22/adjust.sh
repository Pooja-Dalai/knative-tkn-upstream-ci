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

echo "Starting post-install setup..."

# Wait for Kourier namespace and gateway deployment before starting tests.
until kubectl get ns kourier-system >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=available deploy/3scale-kourier-gateway -n kourier-system --timeout=180s || true

# Applying cluster fixes
kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl delete hpa webhook -n knative-serving --ignore-not-found || true
kubectl scale deployment activator --replicas=2 -n knative-serving || true

# Waiting for Knative core components
kubectl rollout status deployment/controller -n knative-serving --timeout=300s
kubectl rollout status deployment/autoscaler -n knative-serving --timeout=300s
kubectl rollout status deployment/activator -n knative-serving --timeout=300s

echo "Giving system time to stabilize..."
sleep 30

# Start port forwarding
echo ">>> Starting Kourier port-forward (NodePort aligned)..."
( while true; do
  kubectl port-forward -n kourier-system service/kourier \
    31470:80 \
    31475:443 >> /tmp/kourier-pf.log 2>&1 || true
  echo ">>> port-forward restarted" >> /tmp/kourier-pf.log
  sleep 5
done ) &
EOF

chmod +x /tmp/post-install-fix.sh

# Run post-install fixes after ingress environment variables are configured
sed -i '/setup_ingress_env_vars/a echo ">>> Running post-install fixes..." ; /tmp/post-install-fix.sh' test/e2e-common.sh

# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml

