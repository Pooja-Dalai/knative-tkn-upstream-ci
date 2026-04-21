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
echo ">>> Applying patch: skip external_address when loopback..."

cat <<'EOF' > /tmp/fix_test.patch
diff --git a/test/e2e/service_to_service_test.go b/test/e2e/service_to_service_test.go
index 3d9a51c46..23b70feb9 100644
--- a/test/e2e/service_to_service_test.go
+++ b/test/e2e/service_to_service_test.go
@@ -28,6 +28,7 @@ import (
 	"testing"

 	netapi "knative.dev/networking/pkg/apis/networking"
+	pkgTest "knative.dev/pkg/test"
 	"knative.dev/pkg/test/logstream"
 	"knative.dev/serving/pkg/apis/autoscaling"
 	"knative.dev/serving/pkg/apis/serving"
@@ -236,6 +237,16 @@ func TestCallToPublicService(t *testing.T) {
 	for _, tc := range gatewayTestCases {
 		t.Run(tc.name, func(t *testing.T) {
 			t.Parallel()
+
+			// Skip external address test if IngressEndpoint is loopback
+			if tc.accessibleExternally {
+				ingressEndpoint := pkgTest.Flags.IngressEndpoint
+				if strings.Contains(ingressEndpoint, "127.0.0.1") || strings.Contains(ingressEndpoint, "localhost") {
+					t.Skip("Skipping external_address test because IngressEndpoint is loopback")
+				}
+			}
+
 			if !test.ServingFlags.DisableLogStream {
 				cancel := logstream.Start(t)
 				defer cancel()
EOF

# Apply patch safely
cd /go/src/github.com/knative/eventing || exit 1

patch -p1 < /tmp/fix_test.patch || echo ">>> Patch may already be applied, continuing..."


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
