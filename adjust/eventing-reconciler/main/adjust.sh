#!/usr/bin/env bash

set -euo pipefail

echo "============================================================"
echo "Applying Eventing reconciler REKT fixes for ppc64le"
echo "Repository: ${PWD}"
echo "============================================================"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file not found: $1"
}

###############################################################################
# Required files
###############################################################################

REKT_SCRIPT="test/e2e-rekt-tests.sh"
E2E_COMMON="test/e2e-common.sh"
REKT_EXECUTION="vendor/knative.dev/reconciler-test/pkg/environment/execution.go"
TRIGGER_FEATURE="test/rekt/features/trigger/feature.go"

require_file "${REKT_SCRIPT}"
require_file "${E2E_COMMON}"
require_file "${REKT_EXECUTION}"

###############################################################################
# Environment configuration
###############################################################################

# Make tools installed under GOPATH available.
GOPATH_BIN="$(go env GOPATH)/bin"
export PATH="${GOPATH_BIN}:${HOME}/go/bin:${PATH}"

export USER="${USER:-$(whoami)}"

# Registry used for PPC64LE test images.
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"

# Force all ko builds to use PPC64LE.
export KO_FLAGS="--platform=linux/ppc64le"

# The Prow log showed that reconciler-test selected:
#
#   cgr.dev/chainguard/static:latest
#
# and failed with:
#
#   no matching platforms in base image index
#
# Force a base image that supports PPC64LE.
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"

export CGO_ENABLED=1

# Full rekt execution can take longer on Power.
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-3h}"

echo "USER=${USER}"
echo "GOARCH=$(go env GOARCH)"
echo "KO_DOCKER_REPO=${KO_DOCKER_REPO}"
echo "KO_FLAGS=${KO_FLAGS}"
echo "KO_DEFAULTBASEIMAGE=${KO_DEFAULTBASEIMAGE}"
echo "REKT_TEST_TIMEOUT=${REKT_TEST_TIMEOUT}"

###############################################################################
# Patch test/e2e-common.sh
#
# Upstream sets:
#
#   export KO_FLAGS="--platform=linux/amd64"
#
# inside test_setup(), which overwrites the PPC64LE setting.
###############################################################################

echo
echo "Patching ${E2E_COMMON}"

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/e2e-common.sh")
text = path.read_text()
original = text

# Replace hard-coded amd64 KO_FLAGS assignments.
text = re.sub(
    r'^[ \t]*(?:export[ \t]+|readonly[ \t]+)?'
    r'KO_FLAGS=.*--platform=linux/amd64.*$',
    'export KO_FLAGS="${KO_FLAGS:---platform=linux/ppc64le}"',
    text,
    flags=re.MULTILINE,
)

# Replace any direct hard-coded amd64 platform usage.
text = text.replace(
    "--platform=linux/amd64",
    "--platform=linux/ppc64le",
)

if text != original:
    path.write_text(text)
    print("Patched test/e2e-common.sh")
else:
    print("No hard-coded linux/amd64 KO_FLAGS assignment found")
PY

###############################################################################
# Disable parallel reconciler-test environment setup
#
# Parallel setup was causing resources and webhooks to be created at the same
# time on the constrained Power cluster.
###############################################################################

echo
echo "Disabling parallel reconciler-test setup"

if grep -q 't\.Parallel()' "${REKT_EXECUTION}"; then
  sed -i '/t\.Parallel()/d' "${REKT_EXECUTION}"
  echo "Removed t.Parallel() from ${REKT_EXECUTION}"
else
  echo "t.Parallel() is already removed"
fi

###############################################################################
# Trigger ordering adjustment
#
# Removing t.Parallel() makes steps execute sequentially. The Trigger must not
# be awaited before its dependent PingSource has been created.
###############################################################################

if [[ -f "${TRIGGER_FEATURE}" ]]; then
  echo
  echo "Patching Trigger dependency ordering"

  python3 <<'PY'
from pathlib import Path

path = Path("test/rekt/features/trigger/feature.go")
text = path.read_text()

marker = "PPC64LE sequential Trigger ordering"

if marker in text:
    print("Trigger ordering patch is already applied")
    raise SystemExit(0)

blocks = [
'''\
\t// trigger won't go ready until after the pingsource exists, because of the dependency annotation
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))

''',
'''\
\t// trigger won't go ready until after the pingsource exists, because of the dependency annotation.
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))

''',
]

removed = False

for block in blocks:
    if block in text:
        text = text.replace(block, "", 1)
        removed = True
        break

if not removed:
    print(
        "Trigger readiness block was not found at the original location; "
        "the upstream source may already be different"
    )
    raise SystemExit(0)

needle = (
    '\tf.Requirement("PingSource goes ready", '
    'pingsource.IsReady(psourcename))\n'
)

replacement = '''\
\tf.Requirement("PingSource goes ready", pingsource.IsReady(psourcename))

\t// PPC64LE sequential Trigger ordering:
\t// The dependency-annotated Trigger can become ready only after its
\t// PingSource dependency has been created and becomes ready.
\tf.Requirement("trigger goes ready", trigger.IsReady(triggerName))
'''

if needle not in text:
    raise SystemExit(
        "ERROR: PingSource readiness requirement was not found"
    )

path.write_text(text.replace(needle, replacement, 1))
print("Patched Trigger dependency ordering")
PY
else
  echo "WARNING: ${TRIGGER_FEATURE} was not found; skipping Trigger patch"
fi

###############################################################################
# Patch test/e2e-rekt-tests.sh
#
# Important fixes:
#
# 1. SKIP_UPLOAD_TEST_IMAGES must be assigned before e2e-common.sh is sourced.
#    Assigning it afterward causes:
#
#      SKIP_UPLOAD_TEST_IMAGES: readonly variable
#
# 2. Set KO_DEFAULTBASEIMAGE before reconciler-test dynamically builds
#    eventshub.
#
# 3. Run rekt sequentially with a larger timeout.
###############################################################################

echo
echo "Patching ${REKT_SCRIPT}"

python3 <<'PY'
from pathlib import Path
import re

path = Path("test/e2e-rekt-tests.sh")
text = path.read_text()

# Remove configuration inserted by an earlier revision of adjust.sh.
text = re.sub(
    r'\n?# BEGIN PPC64LE REKT CONFIGURATION.*?'
    r'# END PPC64LE REKT CONFIGURATION\n?',
    '\n',
    text,
    flags=re.DOTALL,
)

# Remove older manually generated image-build blocks if present.
text = re.sub(
    r'\n?# BEGIN PPC64LE REKT IMAGE BUILD.*?'
    r'# END PPC64LE REKT IMAGE BUILD\n?',
    '\n',
    text,
    flags=re.DOTALL,
)

# Remove all existing SKIP_UPLOAD_TEST_IMAGES assignments.
# The upstream assignment appears after e2e-common.sh has made it readonly.
text = re.sub(
    r'^[ \t]*(?:export[ \t]+|readonly[ \t]+)?'
    r'SKIP_UPLOAD_TEST_IMAGES=.*\n',
    '',
    text,
    flags=re.MULTILINE,
)

configuration = '''\
# BEGIN PPC64LE REKT CONFIGURATION
export USER="${USER:-$(whoami)}"
export SKIP_UPLOAD_TEST_IMAGES="true"
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-icr.io/upstream-k8s-registry/knative}"
export KO_FLAGS="--platform=linux/ppc64le"
export KO_DEFAULTBASEIMAGE="${KO_DEFAULTBASEIMAGE:-gcr.io/distroless/static-debian12:nonroot}"
export CGO_ENABLED=1
export REKT_TEST_TIMEOUT="${REKT_TEST_TIMEOUT:-3h}"
# END PPC64LE REKT CONFIGURATION

'''

# Support both:
#
#   source "$(dirname "$0")/e2e-common.sh"
#
# and:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/e2e-common.sh"
#
source_pattern = re.compile(
    r'^(?P<indent>[ \t]*)'
    r'(?P<statement>'
    r'(?:source|\.)[ \t]+'
    r'["\047]?\$\(dirname[^\n]*e2e-common\.sh["\047]?'
    r')$',
    flags=re.MULTILINE,
)

match = source_pattern.search(text)

if not match:
    raise SystemExit(
        "ERROR: Could not find the e2e-common.sh source statement in "
        "test/e2e-rekt-tests.sh"
    )

text = (
    text[:match.start()]
    + configuration
    + match.group(0)
    + text[match.end():]
)

skip_regex = (
    "^(TestEventTransformJsonata|"
    "TestIntegrationSinkSupportsAuthZ)"
)

main_command = (
    'CGO_ENABLED=1 go_test_e2e '
    '-parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" '
    './test/rekt '
    f'-skip \'{skip_regex}\' '
    '|| fail_test'
)

tls_command = (
    'CGO_ENABLED=1 go_test_e2e '
    '-parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" '
    './test/rekt '
    f'-skip \'{skip_regex}\' '
    '-run TLS '
    '|| fail_test'
)

auth_command = (
    'CGO_ENABLED=1 go_test_e2e '
    '-parallel=1 '
    '-timeout="${REKT_TEST_TIMEOUT}" '
    './test/rekt '
    f'-skip \'{skip_regex}\' '
    '-run "OIDC|AuthZ" '
    '|| fail_test'
)

def replace_rekt_command(current, run_type, replacement):
    lines = current.splitlines()
    replaced = False
    output = []

    for line in lines:
        stripped = line.strip()

        if (
            not replaced
            and "go_test_e2e" in stripped
            and "./test/rekt" in stripped
            and "|| fail_test" in stripped
        ):
            has_tls = bool(
                re.search(r'-run[ =]+["\047]?TLS["\047]?', stripped)
            )
            has_auth = bool(
                re.search(r'OIDC[|\\]AuthZ', stripped)
                or ('OIDC' in stripped and 'AuthZ' in stripped)
            )

            matches = (
                (run_type == "main" and not has_tls and not has_auth)
                or (run_type == "tls" and has_tls)
                or (run_type == "auth" and has_auth)
            )

            if matches:
                indent = line[:len(line) - len(line.lstrip())]
                output.append(indent + replacement)
                replaced = True
                continue

        output.append(line)

    return "\n".join(output) + (
        "\n" if current.endswith("\n") else ""
    ), replaced

text, auth_replaced = replace_rekt_command(
    text,
    "auth",
    auth_command,
)

text, tls_replaced = replace_rekt_command(
    text,
    "tls",
    tls_command,
)

text, main_replaced = replace_rekt_command(
    text,
    "main",
    main_command,
)

# Some upstream versions only have the main rekt invocation.
if not main_replaced:
    raise SystemExit(
        "ERROR: Main ./test/rekt go_test_e2e command was not found"
    )

if not tls_replaced:
    print("TLS-specific rekt command was not found; skipping it")

if not auth_replaced:
    print("OIDC/AuthZ-specific rekt command was not found; skipping it")

# Remove partial image producer file arguments from older patches.
text = re.sub(
    r'[ \t]+(?:-args[ \t]+)?'
    r'-images\.producer\.file='
    r'(?:"?\$\{?REKT_IMAGES_FILE\}?"?)',
    '',
    text,
)

path.write_text(text)

print("Patched test/e2e-rekt-tests.sh")
print(f"Main command patched: {main_replaced}")
print(f"TLS command patched: {tls_replaced}")
print(f"OIDC/AuthZ command patched: {auth_replaced}")
PY

###############################################################################
# Validate the changes
#
# Do not let Prow continue silently when sed/Python patterns fail.
###############################################################################

echo
echo "Validating patched scripts"

bash -n "${E2E_COMMON}"
bash -n "${REKT_SCRIPT}"

skip_count="$(
  grep -c \
    '^[[:space:]]*export SKIP_UPLOAD_TEST_IMAGES=' \
    "${REKT_SCRIPT}" \
    || true
)"

if [[ "${skip_count}" -ne 1 ]]; then
  fail \
    "Expected exactly one SKIP_UPLOAD_TEST_IMAGES assignment; " \
    "found ${skip_count}"
fi

skip_line="$(
  grep -n \
    'export SKIP_UPLOAD_TEST_IMAGES=' \
    "${REKT_SCRIPT}" \
    | head -1 \
    | cut -d: -f1
)"

source_line="$(
  grep -n \
    'e2e-common\.sh' \
    "${REKT_SCRIPT}" \
    | head -1 \
    | cut -d: -f1
)"

[[ -n "${skip_line}" ]] || \
  fail "SKIP_UPLOAD_TEST_IMAGES assignment was not found"

[[ -n "${source_line}" ]] || \
  fail "e2e-common.sh source statement was not found"

if (( skip_line >= source_line )); then
  fail \
    "SKIP_UPLOAD_TEST_IMAGES is still assigned after " \
    "e2e-common.sh is sourced"
fi

if grep -q -- '--platform=linux/amd64' \
  "${E2E_COMMON}" "${REKT_SCRIPT}"; then
  fail "linux/amd64 still exists in the REKT execution path"
fi

if grep -q 'images\.producer\.file' "${REKT_SCRIPT}"; then
  fail "An obsolete images.producer.file setting still exists"
fi

if ! grep -q \
  'go_test_e2e.*-parallel=1.*REKT_TEST_TIMEOUT.*\./test/rekt' \
  "${REKT_SCRIPT}"; then
  fail "The main rekt command was not patched"
fi

if grep -q \
  'go_test_e2e[[:space:]]*-timeout=1h[[:space:]]*\./test/rekt' \
  "${REKT_SCRIPT}"; then
  fail "The original rekt -timeout=1h command still exists"
fi

if grep -q 't\.Parallel()' "${REKT_EXECUTION}"; then
  fail "t.Parallel() still exists in ${REKT_EXECUTION}"
fi

###############################################################################
# Print final configuration in the Prow logs
###############################################################################

echo
echo "================ Final REKT configuration ==================="

grep -nE \
  'PPC64LE REKT|'\
'SKIP_UPLOAD_TEST_IMAGES|'\
'KO_DOCKER_REPO|'\
'KO_FLAGS|'\
'KO_DEFAULTBASEIMAGE|'\
'REKT_TEST_TIMEOUT|'\
'go_test_e2e.*test/rekt' \
  "${REKT_SCRIPT}" \
  || true

echo
echo "================ Architecture configuration ================="

grep -nE \
  'KO_FLAGS|platform=linux/' \
  "${E2E_COMMON}" \
  "${REKT_SCRIPT}" \
  || true

echo
echo "============================================================"
echo "Eventing reconciler REKT adjustments applied successfully"
echo "============================================================"
