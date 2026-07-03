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
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"
export KO_FLAGS="--platform=linux/ppc64le"
export CGO_ENABLED=1

REKT_EXEC="${PWD}/vendor/knative.dev/reconciler-test/pkg/environment/execution.go"
if [[ -f "${REKT_EXEC}" ]]; then
  sed -i '/t\.Parallel()/d' "${REKT_EXEC}"
else
  echo "WARNING: ${REKT_EXEC} missing; rekt Setup step ordering may flake." >&2
fi

python3 <<'PY'
from pathlib import Path

path = Path("test/rekt/features/trigger/feature.go")
if path.exists():
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
    if old in text:
        path.write_text(text.replace(old, new, 1))
PY

echo "Patch e2e-rekt-tests.sh robustly"

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/e2e-rekt-tests.sh")
text = path.read_text()

# Remove readonly/export SKIP_UPLOAD_TEST_IMAGES lines.
text = re.sub(r'^\s*(readonly\s+)?SKIP_UPLOAD_TEST_IMAGES=.*\n', '', text, flags=re.M)
text = re.sub(r'^\s*export\s+SKIP_UPLOAD_TEST_IMAGES=.*\n', '', text, flags=re.M)

# Force upload/build path instead of readonly skip logic.
text = text.replace('${SKIP_UPLOAD_TEST_IMAGES}', 'false')

# Patch every rekt go_test_e2e invocation.
def patch_line(line):
    if "go_test_e2e" not in line or "./test/rekt" not in line:
        return line

    line = re.sub(r'CGO_ENABLED=1\s+', '', line)
    line = re.sub(r'-timeout=\S+', '', line)
    line = re.sub(r'-parallel=\S+', '', line)

    line = line.replace(
        'go_test_e2e ',
        'CGO_ENABLED=1 go_test_e2e -parallel=1 -timeout=${REKT_TEST_TIMEOUT} '
    )

    if '--images.producer.file=/tmp/rekt-images.yaml' not in line:
        line = line.replace(
            './test/rekt',
            './test/rekt --images.producer.file=/tmp/rekt-images.yaml',
            1
        )

    return re.sub(r' +', ' ', line)

text = "\n".join(patch_line(line) for line in text.splitlines()) + "\n"
path.write_text(text)
PY

echo "Build and publish ppc64le reconciler-test images"

EVENTSHUB_IMAGE="$(KO_DOCKER_REPO="${KO_DOCKER_REPO}" KO_FLAGS="${KO_FLAGS}" ko publish ./vendor/knative.dev/reconciler-test/cmd/eventshub)"
echo "EVENTSHUB_IMAGE=${EVENTSHUB_IMAGE}"

cat > /tmp/rekt-images.yaml <<EOF
knative.dev/reconciler-test/cmd/eventshub: ${EVENTSHUB_IMAGE}
EOF

echo "Final rekt commands:"
grep -n "go_test_e2e .*./test/rekt" test/e2e-rekt-tests.sh || true
echo "Image mapping:"
cat /tmp/rekt-images.yaml

export PATH="${HOME}/go/bin:$(go env GOPATH)/bin:${PATH}"

echo "Source code patched successfully"
