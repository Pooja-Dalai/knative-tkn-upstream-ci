#!/bin/bash

echo "Merging conformance tests into e2e tests"
linesofcode=$(grep -A 100 go_test_e2e test/e2e-conformance-tests.sh | grep -v success | tr '\n' ' ')
sed -i "/^success.*/i $linesofcode" test/e2e-tests.sh

echo "Export USER in e2e tests"
sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh

echo "Setting e2e timeout and parallelism"
sed -i "s/\(go_test_e2e.*\)timeout=1h\(.*\).*/\1timeout=15m\2/g" test/e2e-tests.sh
sed -i "s/\(go_test_e2e.*\)parallel=20\(.*\).*/\1parallel=1\2/g" test/e2e-tests.sh

echo "Using ppc64le supported Zipkin image"
sed -i "s|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g" test/config/monitoring/monitoring.yaml

echo "Setting REKT timeout"
export REKT_TEST_TIMEOUT=3h

echo "Removing t.Parallel() from reconciler-test"
sed -i '/t\.Parallel()/d' vendor/knative.dev/reconciler-test/pkg/environment/execution.go

echo "Patching Trigger dependency ordering"
python3 <<'PY'
from pathlib import Path
path = Path("test/rekt/features/trigger/feature.go")
text = path.read_text()
old = """\t// trigger won't go ready until after the pingsource exists, because of the dependency annotation
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))

\tf.Requirement("install pingsource", func(ctx context.Context, t feature.T) {
\t\tbrokeruri, err := broker.Address(ctx, brokerName)
\t\tif err != nil {
\t\t\tt.Error("failed to get address of broker", err)
\t\t}
\t\tcfg := []manifest.CfgFn{
\t\t\tpingsource.WithSchedule("*/1 * * * *"),
\t\t\tpingsource.WithSink(&duckv1.Destination{URI: brokeruri.URL, CACerts: brokeruri.CACerts}),
\t\t\tpingsource.WithData("text/plain", "Test trigger-annotation"),
\t\t}
\t\tpingsource.Install(psourcename, cfg...)(ctx, t)
\t})
\tf.Requirement("PingSource goes ready", pingsource.IsReady(psourcename))
"""
new = """\t// With sequential step execution, install PingSource before waiting for the trigger.
\tf.Requirement("install pingsource", func(ctx context.Context, t feature.T) {
\t\tbrokeruri, err := broker.Address(ctx, brokerName)
\t\tif err != nil {
\t\t\tt.Error("failed to get address of broker", err)
\t\t}
\t\tcfg := []manifest.CfgFn{
\t\t\tpingsource.WithSchedule("*/1 * * * *"),
\t\t\tpingsource.WithSink(&duckv1.Destination{URI: brokeruri.URL, CACerts: brokeruri.CACerts}),
\t\t\tpingsource.WithData("text/plain", "Test trigger-annotation"),
\t\t}
\t\tpingsource.Install(psourcename, cfg...)(ctx, t)
\t})
\tf.Requirement("PingSource goes ready", pingsource.IsReady(psourcename))

\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))
"""
path.write_text(text.replace(old, new, 1))
PY

echo "Building rekt images"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
REKT_IMAGES_FILE="${PWD}/rekt-images.yaml"

EVENTSHUB_IMG=$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/reconciler-test/cmd/eventshub)
HEARTBEATS_IMG=$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/cmd/heartbeats)
PRINT_IMG=$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/test/test_images/print)

cat > "${REKT_IMAGES_FILE}" <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMG}
knative.dev/eventing/cmd/heartbeats: ${HEARTBEATS_IMG}
knative.dev/eventing/test/test_images/print: ${PRINT_IMG}
EOF

echo "Skipping upload of test images"
export SKIP_UPLOAD_TEST_IMAGES=true
sed -i '/^export SKIP_UPLOAD_TEST_IMAGES="true"$/d' test/e2e-rekt-tests.sh

echo "Skipping unsupported rekt tests"
REKT_SKIP_FLAGS=" -skip '^(TestEventTransformJsonata|TestIntegrationSinkSupportsAuthZ)'"

echo "Updating rekt test commands"
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" test/e2e-rekt-tests.sh
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run TLS || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run TLS -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" test/e2e-rekt-tests.sh
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run \"OIDC|AuthZ\" || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run \"OIDC|AuthZ\" -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" test/e2e-rekt-tests.sh
sed -i 's|-timeout= |-timeout="${REKT_TEST_TIMEOUT}" |g' test/e2e-rekt-tests.sh
sed -i 's|^\(go_test_e2e .*\)|CGO_ENABLED=1 \1|g' test/e2e-rekt-tests.sh

echo "Updating PATH"
export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"

echo "Creating artifacts directory"
export ARTIFACTS="${ARTIFACTS:-/root/evr-artifacts/reconcilor-$(date -u +%Y%m%d-%H%M%S)-$$}"
mkdir -p "${ARTIFACTS}"

echo "Source code patched successfully"
