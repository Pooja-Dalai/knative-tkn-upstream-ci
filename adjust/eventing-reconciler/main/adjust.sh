#!/usr/bin/env bash
set -euo pipefail

# Merge conformance test into the main e2e test
linesofcode=$(grep -A 100 go_test_e2e test/e2e-conformance-tests.sh | grep -v success | tr '\n' ' ')
sed -i "/^success.*/i $linesofcode" test/e2e-tests.sh
sed -i "/^source.*/a export USER=$(whoami)" test/e2e-tests.sh
echo "Increase e2e timeout to 60m"
sed -i "s/\(go_test_e2e.*\)timeout=1h\(.*\).*/\1timeout=15m\2/g" test/e2e-tests.sh
sed -i "s/\(go_test_e2e.*\)parallel=20\(.*\).*/\1parallel=1\2/g" test/e2e-tests.sh
echo "Use ppc64le supported zipkin image"
sed -i "s|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g" test/config/monitoring/monitoring.yaml
echo "Source code patched successfully"


echo "Applying Eventing reconciler adjustments for ppc64le (repo: ${PWD})"
export PLATFORM="${PLATFORM:-linux/ppc64le}"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-2h}"
export TRANSFORM_JSONATA_IMAGE="${TRANSFORM_JSONATA_IMAGE:-icr.io/upstream-k8s-registry/knative/transform-jsonata:latest}"
export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"
export ARTIFACTS="${ARTIFACTS:-/root/evr-artifacts/reconciler-$(date -u +%Y%m%d-%H%M%S)-$$}"
mkdir -p "${ARTIFACTS}"


echo "Removing t.Parallel() from reconciler-test setup execution"
sed -i '/t\.Parallel()/d' "${PWD}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"

# Trigger and PingSource dependency ordering fix
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
print("Patched Trigger and PingSource dependency ordering.")
PY

# Build and push Power-compatible REKT images
echo "Building and pushing ppc64le REKT images"
EVENTSHUB_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/reconciler-test/cmd/eventshub)"
HEARTBEATS_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/cmd/heartbeats)"
PRINT_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/test/test_images/print)"

echo "Published eventshub image: ${EVENTSHUB_IMG}"
echo "Published heartbeats image: ${HEARTBEATS_IMG}"
echo "Published print image: ${PRINT_IMG}"

# Generate REKT image mapping
cat > "${PWD}/rekt-images.yaml" <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMG}
knative.dev/eventing/cmd/heartbeats: ${HEARTBEATS_IMG}
knative.dev/eventing/test/test_images/print: ${PRINT_IMG}
EOF

# Prevent e2e-rekt-tests.sh from uploading unsupported images
export SKIP_UPLOAD_TEST_IMAGES=true
sed -i '/^[[:space:]]*export SKIP_UPLOAD_TEST_IMAGES="true"[[:space:]]*$/d' "test/e2e-rekt-tests.sh"

# Create JSONata image patch script, run after the operator installs the ConfigMap
cat > /tmp/patch-jsonata-image.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="knative-eventing"
CONFIGMAP_NAME="eventing-transformations-images"

echo "Applying Power-compatible transform-jsonata image: ${TRANSFORM_JSONATA_IMAGE}"

until kubectl -n "\${NAMESPACE}" get configmap "\${CONFIGMAP_NAME}" >/dev/null 2>&1; do
  sleep 5
done

kubectl -n "\${NAMESPACE}" patch configmap "\${CONFIGMAP_NAME}" --type merge -p '{"data":{"transform-jsonata":"${TRANSFORM_JSONATA_IMAGE}"}}'

kubectl -n "\${NAMESPACE}" rollout restart deployment/eventing-controller
kubectl -n "\${NAMESPACE}" rollout status deployment/eventing-controller --timeout=10m
kubectl -n "\${NAMESPACE}" wait --for=condition=Available deployment --all --timeout=15m

echo "Power-compatible JSONata image configured successfully"
EOF
chmod +x /tmp/patch-jsonata-image.sh

# Inject JSONata patch before the first REKT test execution
python3 <<'PY'
from pathlib import Path
path = Path("test/e2e-rekt-tests.sh")
text = path.read_text()
lines = text.splitlines()
for index, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith("go_test_e2e ") or stripped.startswith("CGO_ENABLED=1 go_test_e2e "):
        indentation = line[:len(line) - len(stripped)]
        lines[index:index] = [f"{indentation}/tmp/patch-jsonata-image.sh", ""]
        path.write_text("\n".join(lines) + "\n")
        print("Injected JSONata image patch before the first REKT command.")
        break
PY

# Configure optional test skips
: "${SKIP_JSONATA_REKT_TESTS:=0}"
: "${SKIP_INTEGRATIONSINK_AUTHZ_REKT_TESTS:=1}"

REKT_SKIP_PARTS=()
[[ "${SKIP_JSONATA_REKT_TESTS}" != "0" ]] && REKT_SKIP_PARTS+=("TestEventTransformJsonata")
[[ "${SKIP_INTEGRATIONSINK_AUTHZ_REKT_TESTS}" != "0" ]] && REKT_SKIP_PARTS+=("TestIntegrationSinkSupportsAuthZ")

REKT_SKIP_FLAGS=""
if ((${#REKT_SKIP_PARTS[@]} > 0)); then
  rekt_skip_joined="${REKT_SKIP_PARTS[*]}"
  rekt_skip_joined="${rekt_skip_joined// /|}"
  REKT_SKIP_FLAGS=" -skip '^(${rekt_skip_joined})'"
fi

# Patch REKT commands with 2-hour timeout, image producer mapping, and CGO enabled
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run TLS || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run TLS -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run \"OIDC|AuthZ\" || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run \"OIDC|AuthZ\" -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"

echo "Adjustments completed successfully
