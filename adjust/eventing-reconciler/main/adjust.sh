#!/bin/bash
set -euo pipefail

# Merge conformance test into the main e2e test
linesofcode=$(grep -A 100 go_test_e2e test/e2e-conformance-tests.sh | grep -v success | tr '\n' ' ')
sed -i "/^success.*/i $linesofcode" test/e2e-tests.sh

sed -i "/^source.*/a export USER=\$(whoami)" test/e2e-tests.sh

echo "Set e2e timeout and parallelism"
sed -i "s/\(go_test_e2e.*\)timeout=1h\(.*\).*/\1timeout=15m\2/g" test/e2e-tests.sh
sed -i "s/\(go_test_e2e.*\)parallel=20\(.*\).*/\1parallel=1\2/g" test/e2e-tests.sh

echo "Use ppc64le supported zipkin image"
sed -i "s|image:.*|image: icr.io/upstream-k8s-registry/knative/openzipkin/zipkin:test|g" test/config/monitoring/monitoring.yaml

#
# Reconciler-test fixes
#

export REKT_TEST_TIMEOUT=2h

REKT_EXEC="${PWD}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"
if [[ -f "${REKT_EXEC}" ]]; then
  sed -i '/t\.Parallel()/d' "${REKT_EXEC}"
else
  echo "WARNING: ${REKT_EXEC} missing; rekt Setup step ordering may flake." >&2
fi

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/rekt/features/trigger/feature.go")

if not path.exists():
    print(f"WARNING: {path} does not exist; skipping Trigger ordering patch.")
    raise SystemExit(0)

text = path.read_text()

marker = "PPC64LE: install PingSource before waiting for Trigger"

if marker in text:
    print("Trigger dependency ordering is already patched.")
    raise SystemExit(0)

trigger_pattern = re.compile(
    r'(?P<comment>[ \t]*//[^\n]*trigger[^\n]*\n)?'
    r'(?P<trigger>[ \t]*f\.Requirement\("trigger goes ready",'
    r'[ \t]*trigger\.IsReady\(triggerName\)\)\n)'
    r'(?P<space>\n*)'
    r'(?P<install>'
    r'[ \t]*f\.Requirement\("install pingsource",'
    r'[ \t]*func\(ctx context\.Context,[ \t]*t feature\.T\)[ \t]*\{\n'
    r'.*?'
    r'[ \t]*\}\)\n'
    r'[ \t]*f\.Requirement\("PingSource goes ready",'
    r'[ \t]*pingsource\.IsReady\(psourcename\)\)\n'
    r')',
    re.DOTALL,
)

match = trigger_pattern.search(text)

if not match:
    print(
        "WARNING: Current feature.go structure differs from the expected "
        "version; skipping Trigger ordering patch."
    )
    raise SystemExit(0)

install_block = match.group("install")

# Preserve the original cfg assignment. Do not change `cfg =` to `cfg :=`,
# because cfg may already be declared outside this requirement function.
replacement = (
    "\t// PPC64LE: install PingSource before waiting for Trigger.\n"
    + install_block
    + '\n\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))\n'
)

text = text[:match.start()] + replacement + text[match.end():]
path.write_text(text)

print("Patched Trigger dependency ordering successfully.")
PY

echo "Use prebuilt ppc64le reconciler-test images"

cat > /tmp/rekt-images.yaml <<'EOF'
knative.dev/reconciler-test/cmd/eventshub: icr.io/upstream-k8s-registry/knative/eventshub:ppc64le
knative.dev/reconciler-test/cmd/eventshub2: icr.io/upstream-k8s-registry/knative/eventshub2:ppc64le
EOF

# Do not skip image handling; use mapped ppc64le images instead.
sed -i '/SKIP_UPLOAD_TEST_IMAGES/d' test/e2e-rekt-tests.sh

sed -i "s#^go_test_e2e -timeout=1h ./test/rekt || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt --images.producer.file=/tmp/rekt-images.yaml || fail_test#" test/e2e-rekt-tests.sh

sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run TLS || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt --images.producer.file=/tmp/rekt-images.yaml -run TLS || fail_test#" test/e2e-rekt-tests.sh

sed -i "s#^go_test_e2e -timeout=1h ./test/rekt -run \"OIDC|AuthZ\" || fail_test\$#go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} ./test/rekt --images.producer.file=/tmp/rekt-images.yaml -run \"OIDC|AuthZ\" || fail_test#" test/e2e-rekt-tests.sh

sed -i 's|-timeout= |-timeout="${REKT_TEST_TIMEOUT}" |g' test/e2e-rekt-tests.sh
sed -i 's|^\(go_test_e2e .*\)|CGO_ENABLED=1 \1|g' test/e2e-rekt-tests.sh

export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"

echo "Source code patched successfully"
