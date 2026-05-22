#!/usr/bin/env bash
# Joins a worker VM to the k3s cluster.
# Run on each worker VM (worker-01, worker-02) as root or with sudo.
# Usage: bash install-worker.sh <MASTER_PRIVATE_IP> <NODE_TOKEN> [WORKER_LABEL]
set -euo pipefail

MASTER_IP="${1:?Usage: $0 <MASTER_PRIVATE_IP> <NODE_TOKEN> [worker-label]}"
NODE_TOKEN="${2:?Usage: $0 <MASTER_PRIVATE_IP> <NODE_TOKEN> [worker-label]}"
WORKER_LABEL="${3:-sfg-worker}"
KUBE_VERSION="${KUBE_VERSION:-v1.29.4+k3s1}"

echo "===> [1/3] Updating system packages"
apt-get update -qq && apt-get upgrade -y -qq

echo "===> [2/3] Joining k3s cluster at ${MASTER_IP}"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${KUBE_VERSION}" \
  K3S_URL="https://${MASTER_IP}:6443" \
  K3S_TOKEN="${NODE_TOKEN}" \
  sh -s - agent \
  --node-label="sfg-role=${WORKER_LABEL}"
  # WireGuard backend is inherited from master — worker joins encrypted overlay automatically

echo "===> [3/3] Verifying agent is running"
systemctl status k3s-agent --no-pager

echo ""
echo "========================================================"
echo "  Worker joined the cluster successfully."
echo "  Verify on master: kubectl get nodes"
echo "========================================================"
