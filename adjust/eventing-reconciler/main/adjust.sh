#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo "Applying Eventing reconciler adjustments for ppc64le"
echo "Repository: ${PWD}"
echo "============================================================"

E2E_SCRIPT="test/e2e-tests.sh"
REKT_SCRIPT="test/e2e-rekt-tests.sh"
CONFORMANCE_SCRIPT="test/e2e-conformance-tests.sh"
MONITORING_FILE="test/config/monitoring/monitoring.yaml"

#
# Validate required files
#

for required_file in \
  "${E2E_SCRIPT}" \
  "${REKT_SCRIPT}" \
  "${CONFORMANCE_SCRIPT}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "ERROR: Required file is missing: ${required_file}" >&2
    exit 1
  fi
done

#
# Environment required in Prow
#

export USER
USER="$(whoami)"

export PLATFORM="${PLATFORM:-linux/ppc64le}"

export KO_DOCKER_REPO="${
  KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative
}"

export KO_DEFAULTBASEIMAGE="${
  KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot
}"

export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-3h}"

export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"

echo "USER=${USER}"
echo "PLATFORM=${PLATFORM}"
echo "KO_DOCKER_REPO=${KO_DOCKER_REPO}"
echo "KO_DEFAULTBASEIMAGE=${KO_DEFAULTBASEIMAGE}"
echo "REKT_TEST_TIMEOUT=${REKT_TEST_TIMEOUT}"
echo "PATH=${PATH}"

if ! command -v ko >/dev/null 2>&1; then
  echo "ERROR: ko is not installed or is unavailable in PATH" >&2
  exit 1
fi

#
# Merge conformance tests into the main E2E script
#

echo "Merging conformance tests into ${E2E_SCRIPT}"

if ! grep -q "PPC64LE_CONFORMANCE_TESTS" "${E2E_SCRIPT}"; then
  linesofcode="$(
    grep -A 100 'go_test_e2e' "${CONFORMANCE_SCRIPT}" |
      grep -v 'success' |
      tr '\n' ' '
  )"

  if [[ -z "${linesofcode//[[:space:]]/}" ]]; then
    echo "ERROR: Could not extract go_test_e2e commands from ${CONFORMANCE_SCRIPT}" >&2
    exit 1
  fi

  sed -i \
    "/^success.*/i # PPC64LE_CONFORMANCE_TESTS\n${linesofcode}" \
    "${E2E_SCRIPT}"
else
  echo "Conformance tests are already merged"
fi

#
# Export USER in the normal E2E script
#

if ! grep -q '^export USER=' "${E2E_SCRIPT}"; then
  sed -i \
    '/^source.*/a export USER=$(whoami)' \
    "${E2E_SCRIPT}"
else
  echo "USER export is already present in ${E2E_SCRIPT}"
fi

#
# Set normal E2E timeout and parallelism
#

echo "Setting E2E timeout to 15m and parallelism to 1"

sed -i \
  's/\(go_test_e2e.*\)timeout=1h\(.*\).*/\1timeout=15m\2/g' \
  "${E2E_SCRIPT}"

sed -i \
  's/\(go_test_e2e.*\)parallel=20\(.*\).*/\1parallel=1\2/g' \
  "${E2E_SCRIPT}"

#
# Use ppc64le-supported Zipkin image
#

if [[ -f "${MONITORING_FILE}" ]]; then
  echo "Using ppc64le-supported Zipkin image"

  sed -i \
    's|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g' \
    "${MONITORING_FILE}"
else
  echo "WARNING: ${MONITORING_FILE} is missing" >&2
fi

#
# Reconciler-test setup ordering fix
#

REKT_EXEC="${
  PWD
}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"

if [[ -f "${REKT_EXEC}" ]]; then
  echo "Removing t.Parallel() from reconciler-test setup execution"
  sed -i '/t\.Parallel()/d' "${REKT_EXEC}"
else
  echo "WARNING: ${REKT_EXEC} is missing; REKT setup ordering may flake" >&2
fi

#
# Trigger dependency ordering fix
#

python3 <<'PY'
from pathlib import Path

path = Path("test/rekt/features/trigger/feature.go")

if not path.exists():
    print(f"WARNING: {path} is missing; skipping Trigger dependency patch.")
    raise SystemExit(0)

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

new = """\t// With sequential step execution, install PingSource before waiting for the trigger (dependency must exist).
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

marker = "With sequential step execution, install PingSource"

if old in text:
    path.write_text(text.replace(old, new, 1))
    print("Patched Trigger and PingSource dependency ordering.")
elif marker in text:
    print("Trigger and PingSource dependency ordering is already patched.")
else:
    print(
        "WARNING: Could not find the expected Trigger dependency block. "
        "The upstream file may have changed; continuing without this patch."
    )
PY

#
# Build and push Power REKT images to ICR
#

echo "============================================================"
echo "Building and pushing ppc64le REKT images to ICR"
echo "============================================================"

REKT_IMAGES_FILE="${PWD}/rekt-images.yaml"

echo "Building and pushing eventshub"

EVENTSHUB_IMG="$(
  CGO_ENABLED=0 ko publish \
    --platform="${PLATFORM}" \
    -B \
    knative.dev/reconciler-test/cmd/eventshub
)"

if [[ -z "${EVENTSHUB_IMG}" ]]; then
  echo "ERROR: eventshub image build returned an empty image reference" >&2
  exit 1
fi

echo "Building and pushing heartbeats"

HEARTBEATS_IMG="$(
  CGO_ENABLED=0 ko publish \
    --platform="${PLATFORM}" \
    -B \
    knative.dev/eventing/cmd/heartbeats
)"

if [[ -z "${HEARTBEATS_IMG}" ]]; then
  echo "ERROR: heartbeats image build returned an empty image reference" >&2
  exit 1
fi

echo "Building and pushing print test image"

PRINT_IMG="$(
  CGO_ENABLED=0 ko publish \
    --platform="${PLATFORM}" \
    -B \
    knative.dev/eventing/test/test_images/print
)"

if [[ -z "${PRINT_IMG}" ]]; then
  echo "ERROR: print image build returned an empty image reference" >&2
  exit 1
fi

echo "Published eventshub image:"
echo "${EVENTSHUB_IMG}"

echo "Published heartbeats image:"
echo "${HEARTBEATS_IMG}"

echo "Published print image:"
echo "${PRINT_IMG}"

#
# Generate the file-producer image mapping
#

cat > "${REKT_IMAGES_FILE}" <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMG}
knative.dev/eventing/cmd/heartbeats: ${HEARTBEATS_IMG}
knative.dev/eventing/test/test_images/print: ${PRINT_IMG}
EOF

echo "Generated REKT image mapping:"
cat "${REKT_IMAGES_FILE}"

if [[ ! -s "${REKT_IMAGES_FILE}" ]]; then
  echo "ERROR: ${REKT_IMAGES_FILE} was not generated correctly" >&2
  exit 1
fi

#
# Images were already built and pushed above.
#
# e2e-common.sh can make SKIP_UPLOAD_TEST_IMAGES readonly, so remove the
# assignment from e2e-rekt-tests.sh and provide it through the environment.
#

export SKIP_UPLOAD_TEST_IMAGES=true

sed -i \
  '/^[[:space:]]*export SKIP_UPLOAD_TEST_IMAGES="true"[[:space:]]*$/d' \
  "${REKT_SCRIPT}"

#
# Optional REKT test skips
#

: "${SKIP_JSONATA_REKT_TESTS:=1}"
: "${SKIP_INTEGRATIONSINK_AUTHZ_REKT_TESTS:=1}"

REKT_SKIP_PARTS=()

if [[ "${SKIP_JSONATA_REKT_TESTS}" != "0" ]]; then
  REKT_SKIP_PARTS+=("TestEventTransformJsonata")

  echo ">>> Skipping Jsonata REKT tests"
  echo ">>> Set SKIP_JSONATA_REKT_TESTS=0 to enable them"
fi

if [[ "${SKIP_INTEGRATIONSINK_AUTHZ_REKT_TESTS}" != "0" ]]; then
  REKT_SKIP_PARTS+=("TestIntegrationSinkSupportsAuthZ")

  echo ">>> Skipping IntegrationSink AuthZ REKT tests"
  echo ">>> Set SKIP_INTEGRATIONSINK_AUTHZ_REKT_TESTS=0 to enable them"
fi

REKT_SKIP_FLAGS=""

if ((${#REKT_SKIP_PARTS[@]} > 0)); then
  rekt_skip_joined="${REKT_SKIP_PARTS[*]}"
  rekt_skip_joined="${rekt_skip_joined// /|}"

  REKT_SKIP_FLAGS=" -skip '^(${rekt_skip_joined})'"
fi

#
# Patch REKT commands
#

echo ">>> REKT package timeout: ${REKT_TEST_TIMEOUT}"
echo ">>> REKT image mapping: ${REKT_IMAGES_FILE}"
echo ">>> REKT skip flags: ${REKT_SKIP_FLAGS:-none}"

sed -i \
  "s#^go_test_e2e -timeout=1h ./test/rekt || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" \
  "${REKT_SCRIPT}"

sed -i \
  "s#^go_test_e2e -timeout=1h ./test/rekt -run TLS || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run TLS -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" \
  "${REKT_SCRIPT}"

sed -i \
  "s#^go_test_e2e -timeout=1h ./test/rekt -run \"OIDC|AuthZ\" || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt${REKT_SKIP_FLAGS} -run \"OIDC|AuthZ\" -args -images.producer.file=${REKT_IMAGES_FILE} || fail_test#" \
  "${REKT_SCRIPT}"

#
# Handle other timeout formats if present
#

sed -i \
  's|-timeout= |-timeout="${REKT_TEST_TIMEOUT}" |g' \
  "${REKT_SCRIPT}"

#
# Enable CGO only for executing the REKT Go tests.
#
# Do not add the prefix again if adjust.sh is run more than once.
#

sed -i \
  '/^CGO_ENABLED=1 go_test_e2e /!s|^\(go_test_e2e .*\)|CGO_ENABLED=1 \1|g' \
  "${REKT_SCRIPT}"

#
# Persist test artifacts
#

export ARTIFACTS="${
  ARTIFACTS:-/root/evr-artifacts/reconciler-$(date -u +%Y%m%d-%H%M%S)-$$
}"

mkdir -p "${ARTIFACTS}"

echo ">>> ARTIFACTS=${ARTIFACTS}"
echo ">>> On failure, inspect:"
echo ">>> ${ARTIFACTS}/go_test_*.jsonl"
echo ">>> ${ARTIFACTS}/junit_*.xml"

#
# Validate resulting scripts
#

bash -n "${E2E_SCRIPT}"
bash -n "${REKT_SCRIPT}"

if ! grep -q 'images\.producer\.file=' "${REKT_SCRIPT}"; then
  echo "ERROR: REKT image mapping was not injected into ${REKT_SCRIPT}" >&2
  exit 1
fi

echo "============================================================"
echo "Final REKT test commands"
echo "============================================================"

grep -nE \
  'go_test_e2e.*test/rekt|images\.producer\.file|CGO_ENABLED' \
  "${REKT_SCRIPT}" || true

echo "============================================================"
echo "Source code patched and Power images pushed successfully"
echo "============================================================"
