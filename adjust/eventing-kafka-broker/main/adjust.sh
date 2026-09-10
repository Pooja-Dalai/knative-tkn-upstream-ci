#!/bin/bash
#Export USER before test starts
sed -i "/^source.*/a export USER=$\(whoami\)" test/e2e-tests.sh
#Increase e2e timeout to 60m
sed -i "s/\(go_test_e2e.*\)timeout=20m\(.*\).*/\1timeout=40m\2/g" test/e2e-tests.sh
# ppc64le.patch is already copied to tmp during setup-environment.sh run
sed -i "s|K8S_VER_MAJOR|$(echo "$K8S_BUILD_VERSION" | sed -E 's/^v([0-9]+)\.([0-9]+)\..*/\1/')|" /tmp/ppc64le.patch
sed -i "s|K8S_VER_MINOR|$(echo "$K8S_BUILD_VERSION" | sed -E 's/^v([0-9]+)\.([0-9]+)\..*/\2/')|" /tmp/ppc64le.patch

# Remove unsupported --zap-log-level flag for keda-adapter v2.11.2
sed -i '/--zap-log-level=error/d' third_party/keda/keda.yaml

# Use Maven archive mirror to avoid rate limiting
sed -i "s|https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip|https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.zip|" data-plane/.mvn/wrapper/maven-wrapper.properties

git apply /tmp/ppc64le.patch
echo "Source code patched successfully"
