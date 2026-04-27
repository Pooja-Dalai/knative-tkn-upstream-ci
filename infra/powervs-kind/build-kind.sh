#!/bin/bash
################################################################################
# build-kind.sh - KinD Cluster Setup for Power (ppc64le)
################################################################################
# Automates installation of Docker, KinD, and kubectl, then creates a 
# multi-node Kubernetes cluster using PowerCloud KinD images.
#
# Prerequisites: CentOS/RHEL system, root access, VSI_IP env var set
# Usage: export VSI_IP="<ip>" && bash build-kind.sh
# Output: KinD cluster 'mkpod' with 1 control-plane + 1 worker node
################################################################################

set -e

# Install Docker
# Add Docker's official GPG key:
sudo dnf update -y
sudo dnf install ca-certificates curl
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git make -y

# Start docker service
systemctl enable docker
systemctl restart docker

# Install Kind
git clone https://github.com/kubernetes-sigs/kind.git
cd kind
make build
cp /root/kind/bin/kind /usr/local/bin/kind
chmod +x /usr/local/bin/kind
cd 

# Install kubectl
curl -LO "https://dl.k8s.io/release/${K8S_BUILD_VERSION}/bin/linux/ppc64le/kubectl"
sudo chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# KinD cluster config
KIND_IMAGE='quay.io/powercloud/kind-node'
KIND_CLUSTER_NAME='mkpod'

# Create kind-config.yaml
cat <<YAML > /root/kind-config.yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
name: ${KIND_CLUSTER_NAME}
nodes:
- extraMounts:
  - containerPath: /var/lib/kubelet/config.json
    hostPath: /root/config.json
  image: ${KIND_IMAGE}:${K8S_BUILD_VERSION}
  role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
      - "${VSI_IP}"
      - "127.0.0.1"
      - "0.0.0.0"
      - "localhost"
  extraPortMappings:
  - containerPort: 6443
    hostPort: 6443
    listenAddress: "0.0.0.0"
    protocol: TCP
- extraMounts:
  - containerPath: /var/lib/kubelet/config.json
    hostPath: /root/config.json
  image: ${KIND_IMAGE}:${K8S_BUILD_VERSION}
  role: worker
YAML

# Create cluster
kind create cluster --config=/root/kind-config.yaml
kubectl get nodes