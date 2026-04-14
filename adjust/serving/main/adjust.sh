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
echo ">>> [1] Starting post-install cluster stabilization..." ; sleep 2 ; \
echo ">>> [2] Deleting autoscaler-hpa..." ; sleep 2 ; \
kubectl delete deployment autoscaler-hpa -n knative-serving --ignore-not-found=true || true ; \
kubectl delete service autoscaler-hpa -n knative-serving --ignore-not-found=true || true ; \
echo ">>> [3] Scaling control plane components..." ; sleep 2 ; \
kubectl scale deployment activator -n knative-serving --replicas=1 || true ; \
kubectl scale deployment controller -n knative-serving --replicas=1 || true ; \
kubectl scale deployment webhook -n knative-serving --replicas=1 || true ; \
echo ">>> [4] Patching autoscaler config..." ; sleep 2 ; \
kubectl patch configmap config-autoscaler -n knative-serving --type merge -p "{\"data\":{\"min-scale\":\"1\",\"max-scale\":\"3\",\"initial-scale\":\"1\",\"scale-down-delay\":\"0s\"}}" || true ; \
echo ">>> [5] Waiting for kourier-system namespace..." ; sleep 2 ; \
until kubectl get ns kourier-system >/dev/null 2>&1; do \
  echo ">>>     still waiting for namespace..." ; sleep 2 ; \
done ; \
echo ">>> [6] Waiting for Kourier deployment..." ; sleep 2 ; \
kubectl wait --for=condition=available deploy/kourier -n kourier-system --timeout=180s || true ; \
echo ">>> [7] Waiting for Kourier endpoints..." ; sleep 2 ; \
until kubectl get endpoints -n kourier-system kourier -o jsonpath=\"{.subsets[0].addresses[0].ip}\" >/dev/null 2>&1; do \
  echo ">>>     waiting for endpoints..." ; sleep 2 ; \
done ; \
echo ">>> [8] Starting Kourier port-forward..." ; sleep 2 ; \
( while true; do \
    kubectl port-forward -n kourier-system service/kourier 80:80 443:443 30080:80 30443:443 >> /tmp/kourier-pf.log 2>&1 || true ; \
    echo ">>> port-forward died, restarting..." >> /tmp/kourier-pf.log ; \
    sleep 2 ; \
  done ) & \
echo ">>> [9] Post-install cluster stabilization completed" ; sleep 2 \
' test/e2e-tests.sh
