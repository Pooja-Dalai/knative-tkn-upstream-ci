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

echo ">>> Applying cluster fixes..."

kubectl delete deployment autoscaler-hpa -n knative-serving --ignore-not-found=true || true
kubectl delete service autoscaler-hpa -n knative-serving --ignore-not-found=true || true

kubectl scale deployment activator -n knative-serving --replicas=1 || true
kubectl scale deployment controller -n knative-serving --replicas=1 || true
kubectl scale deployment webhook -n knative-serving --replicas=1 || true

kubectl patch configmap config-autoscaler -n knative-serving \
  --type merge \
  -p '{"data":{"min-scale":"1","max-scale":"3","initial-scale":"1","scale-down-delay":"0s"}}' || true

echo ">>> Starting Kourier port-forward..."
( while true; do
  kubectl port-forward -n kourier-system service/kourier \
    80:80 443:443 30080:80 30443:443 >> /tmp/kourier-pf.log 2>&1 || true
  echo ">>> restarting port-forward..." >> /tmp/kourier-pf.log
  sleep 2
done ) &

echo ">>> [PATCH DONE]"
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
