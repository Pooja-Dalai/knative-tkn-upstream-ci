# Export USER before test starts, otherwise a test stops
sed -i "/^source.*/a export USER=$\(whoami\)" test/e2e-tests.sh
sed -i "/^initialize.*/a export SHORT=1" test/e2e-tests.sh
# Slow down an interval of kapp checking a status of k8s cluster otherewise will face 'connection refused' frequently
sed -i 's/\(.*run_kapp deploy\)\(.*\)/\1 --wait-check-interval=30s --wait-concurrency=1 --wait-timeout=30m\2/' test/e2e-common.sh
sed -i "/^success.*/i .\/destroy.sh $1" test/e2e-tests.sh
sed -i "/.*dump_cluster_state().*/a\  .\/destroy.sh $1" vendor/knative.dev/hack/infra-library.sh
# Decrease a level of parallelism to 1 (the same as the number of worker nodes in KinD)
sed -i "s/^\(parallelism=\).*/\1\"-parallel 1\"/" test/e2e-tests.sh

# Downgrade the contour release in third_party/contour-latest to release 1.6.0 (due to Envoy)
curl --connect-timeout 10 --retry 5 -L https://github.com/knative-sandbox/net-contour/releases/download/knative-v1.6.0/contour.yaml -o third_party/contour-latest/contour.yaml
curl --connect-timeout 10 --retry 5 -L https://github.com/knative-sandbox/net-contour/releases/download/knative-v1.6.0/net-contour.yaml -o third_party/contour-latest/net-contour.yaml

#Increase delayed-close-timeout
sed -i 's/delayed-close-timeout: 1s/delayed-close-timeout: infinity/g' third_party/contour-latest/contour.yaml
kubectl get cm vcm-script -n default -o jsonpath='{.data.script}' > destroy.sh && chmod +x destroy.sh
#Place overlay
cp /tmp/overlay-ppc64le.yaml test/config/ytt/core/overlay-ppc64le.yaml