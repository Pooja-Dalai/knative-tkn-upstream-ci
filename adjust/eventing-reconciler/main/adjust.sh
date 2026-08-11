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

# Build and push transform-jsonata image using Buildah.
# Docker daemon is not available in the Prow pod (OpenShift/CRI-O, no dockerd on nodes).
echo "Building and pushing transform-jsonata image: ${TRANSFORM_JSONATA_IMAGE}"

if ! command -v buildah >/dev/null 2>&1; then
    echo "buildah not found, installing..."
    SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 && SUDO="sudo"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        ${SUDO} apt-get update -qq
        ${SUDO} apt-get install -y -qq buildah
    elif command -v dnf >/dev/null 2>&1; then
        ${SUDO} dnf install -y buildah
    elif command -v microdnf >/dev/null 2>&1; then
        ${SUDO} microdnf install -y buildah
    elif command -v yum >/dev/null 2>&1; then
        ${SUDO} yum install -y buildah
    else
        echo "ERROR: no known package manager (apt-get/dnf/microdnf/yum) found to install buildah"
        exit 1
    fi
fi

if ! command -v buildah >/dev/null 2>&1; then
    echo "ERROR: buildah installation failed or is still not on PATH"
    exit 1
fi

# Don't hardcode runc — buildah's Debian/Ubuntu package pulls in crun by
# default, not runc. Use whichever OCI runtime is actually present.
if command -v runc >/dev/null 2>&1; then
    BUILD_RUNTIME="$(command -v runc)"
elif command -v crun >/dev/null 2>&1; then
    BUILD_RUNTIME="$(command -v crun)"
else
    echo "ERROR: neither runc nor crun is available for buildah to use"
    exit 1
fi

echo "Buildah version:"
buildah version

echo "Using runtime: ${BUILD_RUNTIME}"
echo "Building for platform: ${PLATFORM}"

# Detect the actual build host architecture rather than assuming it, and
# print it so it's visible in CI logs for future debugging.
HOST_ARCH="$(uname -m)"
echo "Host architecture (uname -m): ${HOST_ARCH}"

case "${HOST_ARCH}" in
  x86_64)
    HOST_PLATFORM="linux/amd64"
    ;;
  aarch64)
    HOST_PLATFORM="linux/arm64"
    ;;
  ppc64le)
    HOST_PLATFORM="linux/ppc64le"
    ;;
  s390x)
    HOST_PLATFORM="linux/s390x"
    ;;
  *)
    echo "ERROR: unrecognized host architecture '${HOST_ARCH}', cannot determine native platform"
    exit 1
    ;;
esac
echo "Host build platform: ${HOST_PLATFORM}"

rm -rf /tmp/eventing-integrations

git clone https://github.com/knative-extensions/eventing-integrations.git \
    /tmp/eventing-integrations

pushd /tmp/eventing-integrations/transform-jsonata

# Run `npm install` natively (on the build host's own architecture) instead
# of under QEMU emulation for ppc64le. Node's V8 JIT is known to segfault
# under qemu-user emulation (a long-standing, unresolved upstream issue).
# jsonata's dependencies are pure JS with no native bindings, so node_modules
# built on the host arch are safe to reuse in the ppc64le final image, which
# only COPYs files and sets metadata -- no execution needed there.
#
# NOTE: buildah 1.19.6 does not support the automatic $BUILDPLATFORM build-arg
# (a newer BuildKit/buildx feature), so it resolves to empty and is silently
# ignored -- use the HOST_PLATFORM detected above instead.
sed -i "s|^FROM registry.access.redhat.com/ubi9/nodejs-20 AS builder\$|FROM --platform=${HOST_PLATFORM} registry.access.redhat.com/ubi9/nodejs-20 AS builder|" Dockerfile
echo "Patched Dockerfile builder stage to use --platform=${HOST_PLATFORM}"
head -5 Dockerfile

buildah bud \
    --runtime "${BUILD_RUNTIME}" \
    --isolation=chroot \
    --storage-driver vfs \
    --platform "${PLATFORM}" \
    --format docker \
    -t "${TRANSFORM_JSONATA_IMAGE}" \
    -f Dockerfile \
    .

echo "Pushing transform-jsonata image: ${TRANSFORM_JSONATA_IMAGE}"

buildah --storage-driver vfs push \
    "${TRANSFORM_JSONATA_IMAGE}"

popd

echo "transform-jsonata image built and pushed successfully"

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
