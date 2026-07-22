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
elif "With sequential step execution, install PingSource" in text:
    pass
else:
    raise SystemExit("adjust.sh: could not patch test/rekt/features/trigger/feature.go")
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
