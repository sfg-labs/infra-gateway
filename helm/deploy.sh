#!/usr/bin/env bash
# Deploys APISIX + Zitadel to the sfg-gateway namespace.
# Run from repo root after kubeconfig is configured.
# Usage: bash helm/deploy.sh [--dry-run]
set -euo pipefail

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="--dry-run"

NAMESPACE="sfg-gateway"

echo "===> [1/5] Adding Helm repos"
# Canonical APISIX chart repo. charts.apiseven.com now 301-redirects here and the redirect
# can hang/fail on CI runners, so point directly at the GitHub Pages URL.
# --force-update makes re-adding an existing repo idempotent without masking real errors.
helm repo add apisix  https://apache.github.io/apisix-helm-chart --force-update
helm repo add zitadel https://charts.zitadel.com                 --force-update
helm repo update

echo "===> [2/5] Ensuring namespaces (sfg-gateway, sfg-apps, sfg-labs)"
kubectl apply -f k8s/namespaces.yaml

echo "===> [2b/5] Installing cert-manager (for Let's Encrypt TLS)"
# Installs CRDs + controller + webhook. Idempotent. The ClusterIssuer/Certificate are applied
# later (step 6) once the webhook is up and APISIX can solve the HTTP-01 challenge.
CERT_MANAGER_VERSION="v1.20.2"
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  echo "    Waiting for cert-manager to be ready..."
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
  kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
fi

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
  ${APISIX_ADMIN_KEY:+--set "apisix.admin.credentials.admin=${APISIX_ADMIN_KEY}"} \
  ${APISIX_ADMIN_KEY:+--set "ingress-controller.config.apisix.adminKey=${APISIX_ADMIN_KEY}"} \
  --wait \
  --timeout 5m \
  ${DRY_RUN}

echo "===> [4b/5] Wiring v2 ingress controller (GatewayProxy + IngressClass)"
# The v2 controller ignores ingress-controller.config.apisix.* and instead needs a GatewayProxy
# that an IngressClass references. Without this, routes never reach APISIX (404 Route Not Found).
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f k8s/gateway-proxy.yaml
  kubectl apply -f k8s/ingressclass.yaml
fi

echo "===> [5/5] Applying service routes"
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f routes/
  kubectl -n "${NAMESPACE}" get apisixroutes
fi

echo "===> [6/6] Applying TLS (cert-manager issuers + Zitadel certificate + ApisixTls)"
# Applied after routes so the apisix IngressClass + GatewayProxy exist for the HTTP-01 challenge.
if [[ -z "${DRY_RUN}" ]]; then
  kubectl apply -f k8s/cert-issuer.yaml
  kubectl apply -f k8s/zitadel-tls.yaml
  echo "    Certificate issuance is async; check with:"
  echo "      kubectl -n ${NAMESPACE} get certificate,order,challenge"
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
