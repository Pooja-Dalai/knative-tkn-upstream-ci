#!/bin/bash

# Export USER before test starts, otherwise a test stops
sed -i "/^source.*/a export USER=$\(whoami\)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh

# Slow down an interval of kapp checking a status of k8s cluster otherewise will face 'connection refused' frequently
sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=45s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh

# Decrease a level of parallelism to 1 (the same as the number of worker nodes in KinD)
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# Set the number of replicas to 1 for stable test results
sed -i 's/\(.*replicas: \).*/\11/' test/config/ytt/ingress/kourier/kourier-replicas.yaml

#Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml

echo ">>> Adjusting Knative control plane..."

sed -i '/serving post-install config/a \
echo ">>> Post-install cluster stabilization starting..." ; \
kubectl delete deployment autoscaler-hpa -n knative-serving --ignore-not-found=true || true ; \
kubectl delete service autoscaler-hpa -n knative-serving --ignore-not-found=true || true ; \
kubectl scale deployment activator -n knative-serving --replicas=1 || true ; \
kubectl scale deployment controller -n knative-serving --replicas=1 || true ; \
kubectl scale deployment webhook -n knative-serving --replicas=1 || true ; \
kubectl patch configmap config-autoscaler -n knative-serving --type merge -p "{\"data\":{\"min-scale\":\"1\",\"max-scale\":\"3\",\"initial-scale\":\"1\",\"scale-down-delay\":\"0s\"}}" || true ; \
echo ">>> Post-install cluster stabilization completed"
' test/e2e-tests.sh
