#!/usr/bin/env bash
# Installs k3s on the master VM (k3s-master at Cantech).
# Run this script directly on the master VM as root or with sudo.
# After completion, copy the NODE_TOKEN printed at the end to use on workers.
set -euo pipefail

KUBE_VERSION="${KUBE_VERSION:-v1.30.2+k3s1}"

echo "===> [1/4] Updating system packages"
apt-get update -qq && apt-get upgrade -y -qq

echo "===> [2/4] Installing k3s control plane"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${KUBE_VERSION}" sh -s - server \
  --cluster-init \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=600 \
  --node-label="sfg-role=master" \
  --flannel-backend=wireguard-native
  # WireGuard encrypts all pod-to-pod traffic between nodes at kernel level

echo "===> [3/4] Waiting for node to become Ready"
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "    ... waiting for node"
  sleep 3
done
kubectl get nodes

echo "===> [4/4] Creating sfg-gateway and sfg-apps namespaces"
kubectl create namespace sfg-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace sfg-apps    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "========================================================"
echo "  k3s master is ready."
echo ""
echo "  NODE_TOKEN (copy this for install-worker.sh):"
cat /var/lib/rancher/k3s/server/node-token
echo ""
echo "  MASTER_PRIVATE_IP:"
hostname -I | awk '{print $1}'
echo "========================================================"
