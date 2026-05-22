#!/usr/bin/env bash
# Pulls the k3s kubeconfig from the master VM to ~/.kube/config on your laptop.
# Usage: bash kubeconfig.sh <MASTER_PUBLIC_IP> [SSH_USER]
set -euo pipefail

MASTER_IP="${1:?Usage: $0 <MASTER_PUBLIC_IP> [ssh-user]}"
SSH_USER="${2:-root}"
LOCAL_KUBECONFIG="${HOME}/.kube/config"
CONTEXT_NAME="sfg-cantech"

echo "===> Fetching kubeconfig from ${SSH_USER}@${MASTER_IP}"
mkdir -p "${HOME}/.kube"

# Fetch, replace the loopback IP with the master's public IP, and name the context.
# Use | as sed delimiter so dots in IPs and slashes in context names are not misinterpreted.
ssh "${SSH_USER}@${MASTER_IP}" "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|127.0.0.1|${MASTER_IP}|g" \
  | sed "s|name: default|name: ${CONTEXT_NAME}|g" \
  | sed "s|cluster: default|cluster: ${CONTEXT_NAME}|g" \
  | sed "s|user: default|user: ${CONTEXT_NAME}|g" \
  | sed "s|current-context: default|current-context: ${CONTEXT_NAME}|g" \
  > /tmp/sfg-kubeconfig

echo "===> Merging into ${LOCAL_KUBECONFIG}"
if [[ -f "${LOCAL_KUBECONFIG}" ]]; then
  KUBECONFIG="${LOCAL_KUBECONFIG}:/tmp/sfg-kubeconfig" \
    kubectl config view --flatten > /tmp/merged-kubeconfig
  mv /tmp/merged-kubeconfig "${LOCAL_KUBECONFIG}"
else
  mv /tmp/sfg-kubeconfig "${LOCAL_KUBECONFIG}"
fi
chmod 600 "${LOCAL_KUBECONFIG}"

echo "===> Switching to context: ${CONTEXT_NAME}"
kubectl config use-context "${CONTEXT_NAME}"
kubectl get nodes

echo ""
echo "========================================================"
echo "  kubeconfig ready. Context: ${CONTEXT_NAME}"
echo "  Run: kubectl get nodes"
echo "========================================================"
