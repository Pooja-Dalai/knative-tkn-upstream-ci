#!/usr/bin/env bash

set -euo pipefail

echo "============================================================"
echo "Applying Eventing reconciler REKT fixes for ppc64le"
echo "Repository: ${PWD}"
echo "============================================================"

REKT_SCRIPT="test/e2e-rekt-tests.sh"
E2E_SCRIPT="test/e2e-tests.sh"
E2E_COMMON="test/e2e-common.sh"
CONFORMANCE_SCRIPT="test/e2e-conformance-tests.sh"
REKT_EXECUTION="vendor/knative.dev/reconciler-test/pkg/environment/execution.go"
TRIGGER_FEATURE="test/rekt/features/trigger/feature.go"
MONITORING_CONFIG="test/config/monitoring/monitoring.yaml"

require_file() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        echo "ERROR: Required file does not exist: ${file}" >&2
        exit 1
    fi
}

require_file "${REKT_SCRIPT}"
require_file "${E2E_SCRIPT}"
require_file "${E2E_COMMON}"
require_file "${CONFORMANCE_SCRIPT}"
require_file "${REKT_EXECUTION}"

#
# Environment configuration
#

export USER
USER="$(whoami)"

export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"
export KO_FLAGS="--platform=linux/ppc64le"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"

# The Prow test container is amd64, but ko builds images for ppc64le.
# CGO must remain disabled during ko cross-compilation; otherwise the amd64
# assembler attempts to compile PowerPC assembly code.
export CGO_ENABLED=0

export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-2h}"

export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"

echo "USER=${USER}"
echo "GOHOSTARCH=$(go env GOHOSTARCH)"
echo "GOARCH=$(go env GOARCH)"
echo "CGO_ENABLED=${CGO_ENABLED}"
echo "KO_DOCKER_REPO=${KO_DOCKER_REPO}"
echo "KO_FLAGS=${KO_FLAGS}"
echo "KO_DEFAULTBASEIMAGE=${KO_DEFAULTBASEIMAGE}"
echo "REKT_TEST_TIMEOUT=${REKT_TEST_TIMEOUT}"
echo

#
# Merge conformance tests into the main e2e script
#

echo "Merging conformance tests into ${E2E_SCRIPT}"

if ! grep -q "PPC64LE CONFORMANCE TESTS" "${E2E_SCRIPT}"; then
    lines_of_code="$(
        grep -A 100 'go_test_e2e' "${CONFORMANCE_SCRIPT}" |
            grep -v 'success' |
            tr '\n' ' '
    )"

    if [[ -z "${lines_of_code// }" ]]; then
        echo "ERROR: Could not extract conformance test command" >&2
        exit 1
    fi

    sed -i \
        "/^success.*/i # PPC64LE CONFORMANCE TESTS\n${lines_of_code}" \
        "${E2E_SCRIPT}"
else
    echo "Conformance test changes already applied"
fi

#
# Add USER to the normal e2e test script
#

if ! grep -q '^export USER=' "${E2E_SCRIPT}"; then
    sed -i \
        '/^source.*/a export USER=$(whoami)' \
        "${E2E_SCRIPT}"
fi

#
# Reduce normal e2e parallelism
#

echo "Setting normal e2e timeout and parallelism"

sed -i -E \
    's/(go_test_e2e.*)-timeout=1h([^[:space:]]*)/\1-timeout=15m\2/g' \
    "${E2E_SCRIPT}"

sed -i -E \
    's/(go_test_e2e.*)-parallel=20([^[:space:]]*)/\1-parallel=1\2/g' \
    "${E2E_SCRIPT}"

sed -i -E \
    's/(go_test_e2e.*)-parallel[[:space:]]+20/\1-parallel 1/g' \
    "${E2E_SCRIPT}"

#
# Use ppc64le-compatible Zipkin image
#

if [[ -f "${MONITORING_CONFIG}" ]]; then
    echo "Configuring ppc64le-supported Zipkin image"

    sed -i \
        's|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g' \
        "${MONITORING_CONFIG}"
else
    echo "WARNING: ${MONITORING_CONFIG} not found; Zipkin image was not changed" >&2
fi

#
# Disable parallel reconciler-test environment setup
#

echo "Disabling parallel reconciler-test setup"

if grep -q 't\.Parallel()' "${REKT_EXECUTION}"; then
    sed -i '/t\.Parallel()/d' "${REKT_EXECUTION}"
    echo "Removed t.Parallel() from ${REKT_EXECUTION}"
else
    echo "t.Parallel() is already absent"
fi

#
# Fix Trigger and PingSource dependency ordering
#

if [[ -f "${TRIGGER_FEATURE}" ]]; then
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
\t\tcfg = []manifest.CfgFn{
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
\t\tcfg = []manifest.CfgFn{
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
    print("Patched Trigger dependency ordering")
elif marker in text:
    print("Trigger dependency ordering was already patched")
else:
    raise SystemExit(
        "adjust.sh: could not find the expected Trigger code block in "
        "test/rekt/features/trigger/feature.go"
    )
PY
else
    echo "WARNING: ${TRIGGER_FEATURE} not found; Trigger ordering was not patched" >&2
fi

#
# Configure prebuilt ppc64le reconciler-test images
#

echo "Creating reconciler-test image mapping"

cat > /tmp/rekt-images.yaml <<'EOF'
knative.dev/reconciler-test/cmd/eventshub: icr.io/upstream-k8s-registry/knative/eventshub:ppc64le
knative.dev/reconciler-test/cmd/eventshub2: icr.io/upstream-k8s-registry/knative/eventshub2:ppc64le
EOF

#
# Patch REKT commands
#

echo "Patching ${REKT_SCRIPT}"

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/e2e-rekt-tests.sh")
text = path.read_text()

begin_marker = "# BEGIN PPC64LE REKT CONFIGURATION"
end_marker = "# END PPC64LE REKT CONFIGURATION"

configuration = """# BEGIN PPC64LE REKT CONFIGURATION
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"
export KO_FLAGS="--platform=linux/ppc64le"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-2h}"
export REKT_IMAGE_MAPPING="/tmp/rekt-images.yaml"
# Disable CGO for ppc64le image cross-compilation performed by ko.
export CGO_ENABLED=0
# END PPC64LE REKT CONFIGURATION
"""

if begin_marker in text and end_marker in text:
    text = re.sub(
        rf"{re.escape(begin_marker)}.*?{re.escape(end_marker)}\n?",
        configuration,
        text,
        count=1,
        flags=re.DOTALL,
    )
else:
    source_match = re.search(
        r"^.*(?:source|\.)[^\n]*e2e-common\.sh[^\n]*$",
        text,
        flags=re.MULTILINE,
    )

    if not source_match:
        raise SystemExit(
            "adjust.sh: could not locate the e2e-common.sh source line in "
            "test/e2e-rekt-tests.sh"
        )

    text = (
        text[:source_match.start()]
        + configuration
        + "\n"
        + text[source_match.start():]
    )

# Remove existing SKIP_UPLOAD_TEST_IMAGES settings because mapped ppc64le
# images are being supplied explicitly.
text = re.sub(
    r"^[ \t]*(?:export[ \t]+)?SKIP_UPLOAD_TEST_IMAGES=.*\n?",
    "",
    text,
    flags=re.MULTILINE,
)

skip_regex = "^(TestEventTransformJsonata|TestIntegrationSinkSupportsAuthZ)"

main_command = (
    'CGO_ENABLED=1 go_test_e2e -parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" ./test/rekt '
    '--images.producer.file="${REKT_IMAGE_MAPPING}" '
    f"-skip '{skip_regex}' || fail_test"
)

tls_command = (
    'CGO_ENABLED=1 go_test_e2e -parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" ./test/rekt '
    '--images.producer.file="${REKT_IMAGE_MAPPING}" '
    f"-skip '{skip_regex}' -run TLS || fail_test"
)

oidc_command = (
    'CGO_ENABLED=1 go_test_e2e -parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" ./test/rekt '
    '--images.producer.file="${REKT_IMAGE_MAPPING}" '
    f'-skip \'{skip_regex}\' -run "OIDC|AuthZ" || fail_test'
)

lines = text.splitlines()
patched_lines = []

main_patched = False
tls_patched = False
oidc_patched = False

for line in lines:
    stripped = line.strip()

    if "go_test_e2e" not in stripped or "./test/rekt" not in stripped:
        patched_lines.append(line)
        continue

    indentation = line[: len(line) - len(line.lstrip())]

    if re.search(r'-run[ =]+"?OIDC\|AuthZ"?', stripped):
        patched_lines.append(indentation + oidc_command)
        oidc_patched = True
    elif re.search(r"-run[ =]+\"?TLS\"?", stripped):
        patched_lines.append(indentation + tls_command)
        tls_patched = True
    elif "-run" not in stripped:
        patched_lines.append(indentation + main_command)
        main_patched = True
    else:
        patched_lines.append(line)

text = "\n".join(patched_lines) + "\n"
path.write_text(text)

print(f"Main REKT command patched: {main_patched}")
print(f"TLS REKT command patched: {tls_patched}")
print(f"OIDC/AuthZ REKT command patched: {oidc_patched}")

if not main_patched:
    raise SystemExit("adjust.sh: main REKT command was not found")

if not tls_patched:
    raise SystemExit("adjust.sh: TLS REKT command was not found")

if not oidc_patched:
    raise SystemExit("adjust.sh: OIDC/AuthZ REKT command was not found")
PY

#
# Validate changes
#

echo
echo "Validating patched scripts"

bash -n "${E2E_SCRIPT}"
bash -n "${E2E_COMMON}"
bash -n "${REKT_SCRIPT}"

if grep -q -- '--platform=linux/amd64' \
    "${E2E_COMMON}" "${REKT_SCRIPT}"; then
    echo "ERROR: Found an unexpected linux/amd64 ko platform setting" >&2
    grep -n -- '--platform=linux/amd64' \
        "${E2E_COMMON}" "${REKT_SCRIPT}" >&2
    exit 1
fi

if ! grep -q 'images\.producer\.file' "${REKT_SCRIPT}"; then
    echo "ERROR: REKT image mapping was not added" >&2
    exit 1
fi

if ! grep -q 'CGO_ENABLED=1 go_test_e2e' "${REKT_SCRIPT}"; then
    echo "ERROR: REKT test commands do not explicitly enable CGO" >&2
    exit 1
fi

if grep -q 't\.Parallel()' "${REKT_EXECUTION}"; then
    echo "ERROR: t.Parallel() is still present in ${REKT_EXECUTION}" >&2
    exit 1
fi

echo
echo "================ Final REKT configuration ==================="

grep -nE \
    'PPC64LE REKT|CGO_ENABLED|KO_DOCKER_REPO|KO_FLAGS|KO_DEFAULTBASEIMAGE|REKT_TEST_TIMEOUT|images\.producer\.file|go_test_e2e.*test/rekt' \
    "${REKT_SCRIPT}" || true

echo
echo "================ Architecture configuration ================="

grep -nE \
    'CGO_ENABLED|KO_FLAGS|platform=linux/' \
    "${E2E_COMMON}" "${REKT_SCRIPT}" || true

echo
echo "================ Image mapping =============================="

cat /tmp/rekt-images.yaml

echo
echo "============================================================"
echo "Eventing reconciler REKT adjustments applied successfully"
echo "============================================================"
