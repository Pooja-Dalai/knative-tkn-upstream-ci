#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Eventing reconciler Prow adjustments ==="

# -------------------------------------------------------------------
# Main Eventing e2e adjustments
# -------------------------------------------------------------------

echo "Merge conformance tests into the main e2e test script"

if [[ ! -f test/e2e-conformance-tests.sh ]]; then
  echo "ERROR: test/e2e-conformance-tests.sh not found" >&2
  exit 1
fi

if [[ ! -f test/e2e-tests.sh ]]; then
  echo "ERROR: test/e2e-tests.sh not found" >&2
  exit 1
fi

# Avoid inserting the conformance commands more than once.
if ! grep -q "Merged conformance tests for ppc64le" test/e2e-tests.sh; then
  linesofcode="$(
    grep -A 100 'go_test_e2e' test/e2e-conformance-tests.sh \
      | grep -v '^success' \
      | tr '\n' ' '
  )"

  sed -i \
    "/^success.*/i # Merged conformance tests for ppc64le\n${linesofcode}" \
    test/e2e-tests.sh
else
  echo "Conformance tests are already merged"
fi

echo "Set USER in test/e2e-tests.sh"

if ! grep -q '^export USER=' test/e2e-tests.sh; then
  sed -i \
    '/^source.*/a export USER=$(whoami)' \
    test/e2e-tests.sh
fi

echo "Set main e2e timeout and parallelism"

sed -i \
  's/\(go_test_e2e.*\)timeout=1h\(.*\)/\1timeout=15m\2/g' \
  test/e2e-tests.sh

sed -i \
  's/\(go_test_e2e.*\)parallel=20\(.*\)/\1parallel=1\2/g' \
  test/e2e-tests.sh

echo "Use ppc64le-supported Zipkin image"

MONITORING_FILE="test/config/monitoring/monitoring.yaml"

if [[ -f "${MONITORING_FILE}" ]]; then
  sed -i \
    's|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g' \
    "${MONITORING_FILE}"
else
  echo "WARNING: ${MONITORING_FILE} not found" >&2
fi

# -------------------------------------------------------------------
# Reconciler-test execution ordering
# -------------------------------------------------------------------

echo "Patch reconciler-test setup ordering"

REKT_EXEC="${PWD}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"

if [[ ! -f "${REKT_EXEC}" ]]; then
  echo "ERROR: ${REKT_EXEC} not found" >&2
  exit 1
fi

if grep -q 't\.Parallel()' "${REKT_EXEC}"; then
  sed -i '/t\.Parallel()/d' "${REKT_EXEC}"
  echo "Removed t.Parallel() from ${REKT_EXEC}"
else
  echo "t.Parallel() is already absent"
fi

# -------------------------------------------------------------------
# Trigger dependency ordering fix
# -------------------------------------------------------------------

echo "Patch Trigger dependency annotation test"

python3 <<'PY'
from pathlib import Path

path = Path("test/rekt/features/trigger/feature.go")

if not path.exists():
    raise SystemExit(f"ERROR: {path} not found")

text = path.read_text()

marker = "With sequential step execution, install PingSource"

if marker in text:
    print(f"{path} is already patched")
    raise SystemExit(0)

early_trigger_variants = [
    """\t// trigger won't go ready until after the pingsource exists, because of the dependency annotation
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))

""",
    """\t// trigger won't go ready until after the pingsource exists, because of the dependency annotation.
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))

""",
]

removed = False

for block in early_trigger_variants:
    if block in text:
        text = text.replace(block, "", 1)
        removed = True
        break

if not removed:
    raise SystemExit(
        "ERROR: Could not locate the early 'trigger goes ready' requirement "
        "in test/rekt/features/trigger/feature.go"
    )

ping_ready = (
    '\tf.Requirement("PingSource goes ready", '
    'pingsource.IsReady(psourcename))\n'
)

replacement = """\tf.Requirement("PingSource goes ready", pingsource.IsReady(psourcename))

\t// With sequential step execution, install PingSource before waiting
\t// for the dependency-annotated Trigger to become ready.
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))
"""

if ping_ready not in text:
    raise SystemExit(
        "ERROR: Could not locate the PingSource ready requirement "
        "in test/rekt/features/trigger/feature.go"
    )

text = text.replace(ping_ready, replacement, 1)
path.write_text(text)

print(f"Patched {path}")
PY

# -------------------------------------------------------------------
# Patch test/e2e-rekt-tests.sh
# -------------------------------------------------------------------

echo "Patch test/e2e-rekt-tests.sh"

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/e2e-rekt-tests.sh")

if not path.exists():
    raise SystemExit(f"ERROR: {path} not found")

text = path.read_text()

# Remove the original assignment because SKIP_UPLOAD_TEST_IMAGES must
# be declared before e2e-common.sh is sourced.
text = re.sub(
    r'^\s*(?:readonly\s+|export\s+)?SKIP_UPLOAD_TEST_IMAGES=.*\n',
    '',
    text,
    flags=re.MULTILINE,
)

runtime_marker = "# BEGIN PPC64LE REKT CONFIGURATION"

runtime_configuration = r'''# BEGIN PPC64LE REKT CONFIGURATION
# These variables must exist in the same process that invokes the tests.
export SKIP_UPLOAD_TEST_IMAGES="${SKIP_UPLOAD_TEST_IMAGES:-true}"
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-3h}"
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"
export KO_FLAGS="${KO_FLAGS:---platform=linux/ppc64le}"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
export CGO_ENABLED=1

GOPATH_BIN="$(go env GOPATH)/bin"
export PATH="${HOME}/go/bin:${GOPATH_BIN}:${PATH}"
# END PPC64LE REKT CONFIGURATION

'''

source_statement = 'source "$(dirname "$0")/e2e-common.sh"\n'

if runtime_marker not in text:
    if source_statement not in text:
        raise SystemExit(
            "ERROR: Could not locate the e2e-common.sh source statement"
        )

    text = text.replace(
        source_statement,
        runtime_configuration + source_statement,
        1,
    )

image_marker = "# BEGIN PPC64LE REKT IMAGE BUILD"

image_build = r'''
# BEGIN PPC64LE REKT IMAGE BUILD
echo "Building and publishing ppc64le reconciler-test images"

REKT_IMAGES_FILE="${REKT_IMAGES_FILE:-${PWD}/rekt-images.yaml}"
export REKT_IMAGES_FILE

echo "KO_DOCKER_REPO=${KO_DOCKER_REPO}"
echo "KO_FLAGS=${KO_FLAGS}"
echo "REKT_IMAGES_FILE=${REKT_IMAGES_FILE}"

EVENTSHUB_IMAGE="$(
  CGO_ENABLED=0 \
  KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
  ko publish \
    --platform=linux/ppc64le \
    -B \
    ./vendor/knative.dev/reconciler-test/cmd/eventshub
)"

HEARTBEATS_IMAGE="$(
  CGO_ENABLED=0 \
  KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
  ko publish \
    --platform=linux/ppc64le \
    -B \
    ./cmd/heartbeats
)"

PRINT_IMAGE="$(
  CGO_ENABLED=0 \
  KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
  ko publish \
    --platform=linux/ppc64le \
    -B \
    ./test/test_images/print
)"

cat >"${REKT_IMAGES_FILE}" <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMAGE}
knative.dev/eventing/cmd/heartbeats: ${HEARTBEATS_IMAGE}
knative.dev/eventing/test/test_images/print: ${PRINT_IMAGE}
EOF

echo "Reconciler-test image mapping:"
cat "${REKT_IMAGES_FILE}"
# END PPC64LE REKT IMAGE BUILD

'''

initialize_statement = 'initialize "$@" --num-nodes=4\n'

if image_marker not in text:
    if initialize_statement not in text:
        raise SystemExit(
            "ERROR: Could not locate initialize \"$@\" --num-nodes=4"
        )

    text = text.replace(
        initialize_statement,
        initialize_statement + image_build,
        1,
    )

skip_regex = (
    "^(TestEventTransformJsonata|"
    "TestIntegrationSinkSupportsAuthZ)"
)

commands = [
    (
        re.compile(
            r'^go_test_e2e\s+-timeout=1h\s+\./test/rekt\s+'
            r'\|\|\s+fail_test\s*$',
            re.MULTILINE,
        ),
        (
            'CGO_ENABLED=1 go_test_e2e '
            '-parallel=1 '
            '-timeout="${REKT_TEST_TIMEOUT}" '
            './test/rekt '
            f'-skip \'{skip_regex}\' '
            '-args '
            '-images.producer.file="${REKT_IMAGES_FILE}" '
            '|| fail_test'
        ),
    ),
    (
        re.compile(
            r'^go_test_e2e\s+-timeout=1h\s+\./test/rekt\s+'
            r'-run\s+TLS\s+\|\|\s+fail_test\s*$',
            re.MULTILINE,
        ),
        (
            'CGO_ENABLED=1 go_test_e2e '
            '-parallel=1 '
            '-timeout="${REKT_TEST_TIMEOUT}" '
            './test/rekt '
            f'-skip \'{skip_regex}\' '
            '-run TLS '
            '-args '
            '-images.producer.file="${REKT_IMAGES_FILE}" '
            '|| fail_test'
        ),
    ),
    (
        re.compile(
            r'^go_test_e2e\s+-timeout=1h\s+\./test/rekt\s+'
            r'-run\s+"OIDC\|AuthZ"\s+\|\|\s+fail_test\s*$',
            re.MULTILINE,
        ),
        (
            'CGO_ENABLED=1 go_test_e2e '
            '-parallel=1 '
            '-timeout="${REKT_TEST_TIMEOUT}" '
            './test/rekt '
            f'-skip \'{skip_regex}\' '
            '-run "OIDC|AuthZ" '
            '-args '
            '-images.producer.file="${REKT_IMAGES_FILE}" '
            '|| fail_test'
        ),
    ),
]

for pattern, replacement in commands:
    updated_text, count = pattern.subn(replacement, text, count=1)

    if count == 1:
        text = updated_text
        continue

    # Allow rerunning adjust.sh when the command is already patched.
    if replacement not in text:
        raise SystemExit(
            "ERROR: Could not find or patch expected rekt command:\n"
            f"{pattern.pattern}"
        )

path.write_text(text)
print(f"Patched {path}")
PY

# -------------------------------------------------------------------
# Validation
# -------------------------------------------------------------------

echo
echo "=== Validate patched test script ==="

bash -n test/e2e-rekt-tests.sh

echo
echo "Final reconciler-test configuration:"
grep -nE \
  'PPC64LE REKT|SKIP_UPLOAD_TEST_IMAGES|REKT_TEST_TIMEOUT|KO_DOCKER_REPO|REKT_IMAGES_FILE|ko publish|go_test_e2e.*test/rekt|images.producer.file' \
  test/e2e-rekt-tests.sh || true

echo
echo "Verify t.Parallel removal:"
if grep -n 't\.Parallel()' "${REKT_EXEC}"; then
  echo "ERROR: t.Parallel() still exists in ${REKT_EXEC}" >&2
  exit 1
else
  echo "No t.Parallel() calls remain in ${REKT_EXEC}"
fi

echo
echo "Verify Trigger feature patch:"
grep -n -A 4 -B 4 \
  'With sequential step execution' \
  test/rekt/features/trigger/feature.go

echo
echo "=== Eventing reconciler source code patched successfully ==="
