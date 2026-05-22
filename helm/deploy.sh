#!/usr/bin/env bash
# Deploys APISIX + Zitadel to the sfg-gateway namespace.
# Run from repo root after kubeconfig is configured.
# Usage: bash helm/deploy.sh [--dry-run]
set -euo pipefail

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="--dry-run"

NAMESPACE="sfg-gateway"

echo "===> [1/5] Adding Helm repos"
helm repo add apisix  https://charts.apiseven.com  2>/dev/null || true
helm repo add zitadel https://charts.zitadel.com   2>/dev/null || true
helm repo update

echo "===> [2/5] Ensuring namespace ${NAMESPACE} exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace sfg-apps       --dry-run=client -o yaml | kubectl apply -f -

echo "===> [3/5] Installing Zitadel"
# Zitadel must be deployed before APISIX so its service is reachable for OIDC discovery
if [[ -z "${DRY_RUN}" ]]; then
  if ! kubectl -n "${NAMESPACE}" get secret zitadel-masterkey &>/dev/null; then
    echo "    Generating Zitadel master key secret..."
    kubectl -n "${NAMESPACE}" create secret generic zitadel-masterkey \
      --from-literal=masterkey="$(openssl rand -base64 32)"
  fi
fi

helm upgrade --install sfg-zitadel zitadel/zitadel \
  --namespace "${NAMESPACE}" \
  --values helm/zitadel/values.yaml \
  --wait \
  --timeout 5m \
  ${DRY_RUN}

echo "===> [4/5] Installing APISIX + Ingress Controller"
if [[ -z "${DRY_RUN}" ]]; then
  if ! kubectl -n "${NAMESPACE}" get secret apisix-admin-key &>/dev/null; then
    echo "    Generating APISIX admin key secret..."
    kubectl -n "${NAMESPACE}" create secret generic apisix-admin-key \
      --from-literal=key="$(openssl rand -hex 16)"
  fi
  APISIX_ADMIN_KEY="$(kubectl -n "${NAMESPACE}" get secret apisix-admin-key \
    -o jsonpath='{.data.key}' | base64 -d)"
fi

helm upgrade --install sfg-apisix apisix/apisix \
  --namespace "${NAMESPACE}" \
  --values helm/apisix/values.yaml \
  ${APISIX_ADMIN_KEY:+--set "ingress-controller.config.apisix.adminKey=${APISIX_ADMIN_KEY}"} \
  --wait \
  --timeout 5m \
  ${DRY_RUN}

echo "===> [5/5] Applying service routes"
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f routes/
  kubectl -n "${NAMESPACE}" get apisixroutes
fi

echo ""
echo "========================================================"
echo "  Gateway deployed successfully."
echo ""
echo "  APISIX pods:"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=apisix 2>/dev/null || true
echo ""
echo "  Zitadel pods:"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=zitadel 2>/dev/null || true
echo ""
echo "  Next: Configure your DNS to point to the master IP"
echo "        Then run: bash tests/smoke/smoke-test.sh https://api.nma-india.in"
echo "========================================================"
