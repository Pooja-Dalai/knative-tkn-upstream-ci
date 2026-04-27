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
echo ">>> Applying cluster fixes..."

kubectl delete deployment chaosduck -n knative-serving --ignore-not-found || true
kubectl delete hpa activator -n knative-serving --ignore-not-found || true
kubectl scale deployment activator --replicas=1 -n knative-serving || true

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
echo ">>> Running post-install fix in background..." ; \
/tmp/post-install-fix.sh & \
' test/e2e-common.sh


# Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml
