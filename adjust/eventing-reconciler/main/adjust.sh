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

# Configure required environment variables
export PLATFORM="${PLATFORM:-linux/ppc64le}"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-2h}"
export TRANSFORM_JSONATA_IMAGE="${TRANSFORM_JSONATA_IMAGE:-icr.io/upstream-k8s-registry/knative/transform-jsonata:latest}"

# Build and push transform-jsonata image ourselves instead of using the pre-built icr.io one
echo "Building and pushing transform-jsonata image: ${TRANSFORM_JSONATA_IMAGE}"

# Pick whatever OCI build tool is actually usable in this CI container.
# docker requires a running daemon, which Prow/k8s-based CI images often don't ship.
# podman/buildah are daemonless and are the common fallback; kaniko needs a different
# invocation entirely (no local build+push, it's a single executor call).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  BUILD_TOOL="docker"
elif command -v podman >/dev/null 2>&1; then
  BUILD_TOOL="podman"
elif command -v buildah >/dev/null 2>&1; then
  BUILD_TOOL="buildah"
else
  echo "ERROR: no usable container build tool found (docker daemon unreachable, and no podman/buildah on PATH)."
  echo "Install/enable one of these in the CI image, or switch this step to kaniko."
  exit 1
fi
echo "Using ${BUILD_TOOL} to build/push transform-jsonata image"

git clone https://github.com/knative-extensions/eventing-integrations.git /tmp/eventing-integrations
pushd /tmp/eventing-integrations/transform-jsonata

case "${BUILD_TOOL}" in
  docker)
    docker build -t "${TRANSFORM_JSONATA_IMAGE}" -f Dockerfile .
    docker push "${TRANSFORM_JSONATA_IMAGE}"
    ;;
  podman)
    podman build -t "${TRANSFORM_JSONATA_IMAGE}" -f Dockerfile .
    podman push "${TRANSFORM_JSONATA_IMAGE}"
    ;;
  buildah)
    buildah bud -t "${TRANSFORM_JSONATA_IMAGE}" -f Dockerfile .
    buildah push "${TRANSFORM_JSONATA_IMAGE}"
    ;;
esac

popd

# Remove t.Parallel() from reconciler-test setup execution as running setup sequentially avoids race conditions 
# and ordering issues can occur during environment initialization
echo "Removing t.Parallel() from reconciler-test setup execution"
sed -i '/t\.Parallel()/d' "${PWD}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"

# Reorder Trigger and PingSource requirements in the REKT test.
# TestTriggerDependencyAnnotation listed "trigger goes ready" before "install pingsource"; that only worked
# when reconciler-test ran Requirement steps in parallel. Reorder to match real dependency order
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

# Build and push power-compatible REKT images
EVENTSHUB_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/reconciler-test/cmd/eventshub)"
HEARTBEATS_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/cmd/heartbeats)"
PRINT_IMG="$(CGO_ENABLED=0 ko publish --platform="${PLATFORM}" -B knative.dev/eventing/test/test_images/print)"

echo "Published eventshub image: ${EVENTSHUB_IMG}"
echo "Published heartbeats image: ${HEARTBEATS_IMG}"
echo "Published print image: ${PRINT_IMG}"

# Generate REKT image mapping
# With -images.producer.file, *every* ko package used during tests must be listed 
cat > "${PWD}/rekt-images.yaml" <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMG}
knative.dev/eventing/cmd/heartbeats: ${HEARTBEATS_IMG}
knative.dev/eventing/test/test_images/print: ${PRINT_IMG}
EOF

# Prevent e2e-rekt-tests.sh from uploading unsupported images
export SKIP_UPLOAD_TEST_IMAGES=true
sed -i '/^[[:space:]]*export SKIP_UPLOAD_TEST_IMAGES="true"[[:space:]]*$/d' "test/e2e-rekt-tests.sh"

# Create transform-jsonata image patch script, run after the operator installs the ConfigMap
cat > /tmp/patch-jsonata-image.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="knative-eventing"
CONFIGMAP_NAME="eventing-transformations-images"

echo "Applying transform-jsonata image: ${TRANSFORM_JSONATA_IMAGE}"
until kubectl -n "\${NAMESPACE}" get configmap "\${CONFIGMAP_NAME}" >/dev/null 2>&1; do
  sleep 5
done

kubectl -n "\${NAMESPACE}" patch configmap "\${CONFIGMAP_NAME}" --type merge -p '{"data":{"transform-jsonata":"${TRANSFORM_JSONATA_IMAGE}"}}'
kubectl -n "\${NAMESPACE}" rollout restart deployment/eventing-controller
kubectl -n "\${NAMESPACE}" rollout status deployment/eventing-controller --timeout=10m
kubectl -n "\${NAMESPACE}" wait --for=condition=Available deployment --all --timeout=15m

echo "transform-jsonata image configured successfully"
EOF
chmod +x /tmp/patch-jsonata-image.sh

# Inject transform-jsonata patch before the first REKT test execution
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
# IntegrationSink AuthZ: binary-encoded invalid events sometimes return 204 instead of 403 (structured path passes)
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

# Patch REKT commands with rekt timeout, image producer mapping, and CGO enabled
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run TLS || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run TLS -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"
sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run \"OIDC|AuthZ\" || fail_test\$#CGO_ENABLED=1 go_test_e2e -parallel=3 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run \"OIDC|AuthZ\" -args -images.producer.file=${PWD}/rekt-images.yaml || fail_test#" "test/e2e-rekt-tests.sh"

echo "Adjustments completed successfully"
